import Foundation
import Darwin
import IOKit
import OSLog

/// Percent is the gauge state of charge macOS displays (menu bar, pmset); health is the
/// System Settings "Maximum Capacity" when `SystemHealthMonitor` has it, else nominal/design.
func batteryReading(systemHealth: Double? = nil) -> Reading {
    let info = FetchBatteryInfo()
    guard info.max_capacity > 0, info.design_capacity > 0 else {
        return Reading(percent: -1, health: 0, plugged: false, charging: false, cycles: 0)
    }
    let gauge = (0...100).contains(info.state_of_charge) ? Double(info.state_of_charge)
        : Double(info.current_capacity) / Double(info.max_capacity) * 100
    return Reading(percent: gauge,
                   health: systemHealth ?? Double(info.max_capacity) / Double(info.design_capacity) * 100,
                   plugged: info.is_plugged_in, charging: info.is_charging, cycles: Int(info.cycle_count),
                   batteryWatts: Double(info.battery_power_mw) / 1000, adapterWatts: Double(info.adapter_power_mw) / 1000,
                   systemWatts: Double(info.system_power_mw) / 1000)
}

/// powerd's filtered "Maximum Capacity" is only handed to callers with a private entitlement;
/// `system_profiler` is one, so its JSON is read in the background every few minutes.
final class SystemHealthMonitor {
    private(set) var value: Double?
    private var refreshed = Date.distantPast
    private var running = false
    func refreshIfStale(interval: TimeInterval = 300) {
        guard !running, Date().timeIntervalSince(refreshed) >= interval else { return }
        running = true
        DispatchQueue.global(qos: .utility).async {
            let health = SystemHealthMonitor.read()
            DispatchQueue.main.async { self.value = health ?? self.value; self.refreshed = Date(); self.running = false }
        }
    }
    static func read() -> Double? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPPowerDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["SPPowerDataType"] as? [[String: Any]] else { return nil }
        for entry in entries {
            guard let text = (entry["sppower_battery_health_info"] as? [String: Any])?["sppower_battery_health_maximum_capacity"] as? String,
                  text.hasSuffix("%"), let value = Double(text.dropLast()), value > 0, value <= 100 else { continue }
            return value
        }
        return nil
    }
}

/// Charge-inhibit keys differ by firmware: CHTE (macOS 15.7–26), CH0B/CH0C (older),
/// none on the firmware shipped with macOS 27 and the 15.8 / 26.7 updates. The adapter
/// cut-off key (CHIE, else CH0J/CH0I) is what actually drives the discharge phase, so
/// cycling works with it alone; the inhibit keys are applied when the firmware has them.
func writeCharging(_ enabled: Bool) throws {
    func exists(_ key: String) -> Bool {
        var buffer = [CChar](repeating: 0, count: 32)
        return SmcReadKey(key, &buffer, 32) == 0
    }
    func write(_ key: String, _ value: String) -> Bool { SmcWriteKey(key, value) == 0 }
    let inhibit: [(String, String)]
    if exists("CHTE") { inhibit = [("CHTE", enabled ? "00000000" : "01000000")] }
    else if exists("CH0B") { inhibit = [("CH0B", enabled ? "00" : "02"), ("CH0C", enabled ? "00" : "02")] }
    else { inhibit = [] }
    let adapter: [(String, String)] = exists("CHIE") ? [("CHIE", enabled ? "00" : "08")]
        : [("CH0J", enabled ? "00" : "01"), ("CH0I", enabled ? "00" : "01")]
    var failures = [String]()
    for (key, value) in inhibit where !write(key, value) {
        failures.append(key)
        // Never cut the adapter when the firmware refused to stop charging.
        if !enabled { throw AppError.message("SMC 写入失败：" + failures.joined(separator: ", ")) }
    }
    if !adapter.contains(where: { write($0.0, $0.1) }) {
        failures.append(adapter.map(\.0).joined(separator: "/"))
        if inhibit.isEmpty {
            throw AppError.message("此固件没有可用的充电控制键（CHTE/CH0B/CHIE 均不可写），无法控制电池。")
        }
    }
    if !failures.isEmpty { throw AppError.message("SMC 写入失败：" + failures.joined(separator: ", ")) }
}

/// Cutting the adapter puts the Mac on battery, and macOS then sleeps within seconds with the
/// lid closed (clamshell) or after the battery idle timer otherwise; the app restores charging
/// before any sleep, so a discharge phase could never progress. Power assertions do not stop
/// clamshell sleep, so system sleep is switched off (`pmset disablesleep`) for the discharge
/// phase and put back to the user's setting afterwards. The marker file records a hold that
/// this helper owns, so a helper killed mid-phase is undone by the next one.
///
/// Re-enabling sleep the instant the adapter is restored runs the clamshell sleep that was
/// raised while it was away (measured: display off at once, asleep five seconds later), so the
/// release waits until IOKit reports the adapter and then a settle period.
final class SleepHold {
    static let settle: TimeInterval = 20
    private let marker = "/var/run/batterytool-sleep-disabled"
    private let userDisabled: Bool
    private let lock = NSLock()
    private var held = false
    private var generation = 0
    private let log = Logger(subsystem: "local.batterytool.manager", category: "sleep")
    init() {
        if FileManager.default.fileExists(atPath: marker) {
            _ = SleepHold.pmset(disable: false)
            unlink(marker)
        }
        userDisabled = SleepHold.registryBool(service: "IOPMrootDomain", key: "SleepDisabled")
    }
    func hold() throws {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        guard !held, !userDisabled else { return }
        guard SleepHold.pmset(disable: true) else { throw AppError.message("无法在放电期间禁止系统睡眠（pmset disablesleep）") }
        held = true
        FileManager.default.createFile(atPath: marker, contents: nil, attributes: [.posixPermissions: 0o600])
        log.notice("sleep disabled for discharge")
    }
    /// Immediate release: only for failure paths, where the adapter may not be back.
    func release() {
        lock.lock(); defer { lock.unlock() }
        releaseLocked()
    }
    /// Blocks until the adapter is back and settled, then re-enables sleep.
    func releaseSettled() {
        lock.lock(); let token = generation; let active = held; lock.unlock()
        guard active else { return }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !SleepHold.adapterConnected() { Thread.sleep(forTimeInterval: 0.25) }
        log.notice("adapter back, settling \(Int(SleepHold.settle), privacy: .public)s before re-enabling sleep")
        Thread.sleep(forTimeInterval: SleepHold.settle)
        lock.lock(); defer { lock.unlock() }
        // A newer discharge took the hold again during the settle; keep it.
        guard generation == token else { return }
        releaseLocked()
    }
    /// Same as `releaseSettled` without blocking the caller (the command socket has a 2 s timeout).
    func releaseSettledInBackground() {
        DispatchQueue.global(qos: .userInitiated).async { self.releaseSettled() }
    }
    private func releaseLocked() {
        guard held else { return }
        if SleepHold.pmset(disable: false) { held = false; unlink(marker); log.notice("sleep re-enabled") }
        else { log.error("Could not re-enable system sleep") }
    }
    static func adapterConnected() -> Bool {
        registryBool(service: "AppleSmartBattery", key: "ExternalConnected")
    }
    static func registryBool(service: String, key: String) -> Bool {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(service))
        guard entry != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(entry) }
        let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? Bool) ?? false
    }
    private static func pmset(disable: Bool) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["disablesleep", disable ? "1" : "0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

/// Production power transitions: sleep is held before the adapter is cut and given back, settled,
/// after it is restored, so the Mac is never left asleep-capable on battery or sleep-locked on AC.
func applyPowerState(_ enabled: Bool, sleepHold: SleepHold) throws {
    if enabled {
        do { try writeCharging(true) } catch { sleepHold.release(); throw error }
        sleepHold.releaseSettledInBackground()
    } else {
        try sleepHold.hold()
        do { try writeCharging(false) } catch { sleepHold.release(); throw error }
    }
}

private func socketAddress(_ path: String) -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { bytes in
        for (index, byte) in path.utf8.prefix(bytes.count - 1).enumerated() { bytes[index] = byte }
    }
    return address
}
private func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    var address = socketAddress(path)
    return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}
private func configureSocket(_ fd: Int32) {
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
}
private func readLineFromSocket(_ fd: Int32) -> String? {
    let began = ProcessInfo.processInfo.systemUptime
    var bytes = [UInt8]()
    var byte: UInt8 = 0
    while bytes.count < 256 && ProcessInfo.processInfo.systemUptime - began < 2 {
        guard recv(fd, &byte, 1, 0) == 1 else { return nil }
        if byte == 10 { return String(bytes: bytes, encoding: .utf8) }
        bytes.append(byte)
    }
    return nil
}
private func sendLine(_ fd: Int32, _ line: String) {
    let bytes = Array((line + "\n").utf8)
    bytes.withUnsafeBytes { buffer in _ = send(fd, buffer.baseAddress, buffer.count, 0) }
}

/// Root helper accepts only fixed operations from the original local user.
/// The heartbeat lease restores charging if the UI crashes or disappears.
func runHelper(uid: uid_t, token: String) -> Int32 {
    guard geteuid() == 0, uid > 0, UUID(uuidString: token) != nil else { return 1 }
    let lock = open("/var/run/batterytool-control.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard lock >= 0 else { return 1 }
    defer { close(lock) }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return 1 }
    let sleepHold = SleepHold()
    let status = servePowerCommands(uid: uid, token: token, path: "/var/run/batterytool-\(uid).sock") {
        try applyPowerState($0, sleepHold: sleepHold)
    }
    // The process must not exit with sleep still disabled; the client already has its reply.
    sleepHold.releaseSettled()
    return status
}

/// Testable transport: production always supplies the fixed SMC implementation above.
func servePowerCommands(uid: uid_t, token: String, path: String, lease: Double = 12,
                        apply: (Bool) throws -> Void) -> Int32 {
    func restore() {
        do { try apply(true) }
        catch { Logger(subsystem: "local.batterytool.manager", category: "power").error("Charging restoration failed: \(error.localizedDescription, privacy: .public)") }
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return 1 }
    unlink(path)
    defer { close(fd); unlink(path); restore() }
    guard withAddress(path, { bind(fd, $0, $1) }) == 0 else { return 1 }
    guard chown(path, uid, gid_t.max) == 0, chmod(path, 0o600) == 0, listen(fd, 4) == 0 else { return 1 }
    var lastContact = ProcessInfo.processInfo.systemUptime
    while ProcessInfo.processInfo.systemUptime - lastContact < lease {
        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pollFD, 1, 500) > 0 else { continue }
        let client = accept(fd, nil, nil)
        guard client >= 0 else { continue }
        defer { close(client) }
        configureSocket(client)
        var peer: uid_t = 0
        var group: gid_t = 0
        guard getpeereid(client, &peer, &group) == 0, peer == uid,
              let line = readLineFromSocket(client) else { continue }
        let parts = line.split(separator: " ")
        guard parts.count == 2, parts[0] == token else { sendLine(client, "ERROR unauthorized"); continue }
        let command = String(parts[1])
        guard ["ping", "charge", "discharge", "quit"].contains(command) else { continue }
        lastContact = ProcessInfo.processInfo.systemUptime
        do {
            if command == "charge" || command == "quit" { try apply(true) }
            if command == "discharge" { try apply(false) }
            sendLine(client, "OK")
            if command == "quit" { return 0 }
        } catch {
            sendLine(client, "ERROR " + error.localizedDescription)
            restore()
            if command == "quit" { return 1 }
        }
    }
    return 0
}

final class HardwareClient {
    private let token: String
    private let uid = getuid()
    private let socketPath: String
    private let expectedServer: uid_t
    init(token: String = UUID().uuidString, socketPath: String? = nil, expectedServer: uid_t = 0) {
        self.token = token
        self.socketPath = socketPath ?? "/var/run/batterytool-\(getuid()).sock"
        self.expectedServer = expectedServer
    }
    var authorized = false
    func request(_ command: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AppError.message("无法创建电源控制连接") }
        defer { close(fd) }
        configureSocket(fd)
        guard withAddress(socketPath, { connect(fd, $0, $1) }) == 0 else {
            authorized = false
            throw AppError.message("电源服务未连接，请授权；也请检查是否有命令行循环正在运行。")
        }
        var peer: uid_t = 1
        var group: gid_t = 0
        guard getpeereid(fd, &peer, &group) == 0, peer == expectedServer else { throw AppError.message("电源服务身份无效") }
        sendLine(fd, "\(token) \(command)")
        guard let response = readLineFromSocket(fd) else {
            authorized = false
            throw AppError.message("电源服务响应超时，已停止任务。")
        }
        guard response == "OK" else { throw AppError.message(response) }
        if command == "quit" { authorized = false }
    }
    func authorize(completion: @escaping (String?) -> Void) {
        let executable = Bundle.main.executableURL!.path
        func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = "\(shellQuote(executable)) --helper \(uid) \(shellQuote(token)) </dev/null >/dev/null 2>&1 &"
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
            do {
                try process.run(); process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw AppError.message("授权取消或失败") }
                var lastError: Error?
                for _ in 0..<20 {
                    do { try self.request("ping"); lastError = nil; break }
                    catch { lastError = error; Thread.sleep(forTimeInterval: 0.1) }
                }
                if let lastError { throw lastError }
                DispatchQueue.main.async { self.authorized = true; completion(nil) }
            } catch { DispatchQueue.main.async { completion(error.localizedDescription) } }
        }
    }
}
