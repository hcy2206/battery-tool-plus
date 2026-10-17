import Foundation
import Darwin
import OSLog

func batteryReading() -> Reading {
    let info = FetchBatteryInfo()
    guard info.max_capacity > 0, info.design_capacity > 0 else {
        return Reading(percent: -1, health: 0, plugged: false, charging: false, cycles: 0)
    }
    return Reading(percent: Double(info.current_capacity) / Double(info.max_capacity) * 100,
                   health: Double(info.max_capacity) / Double(info.design_capacity) * 100,
                   plugged: info.is_plugged_in, charging: info.is_charging, cycles: Int(info.cycle_count))
}

func writeCharging(_ enabled: Bool) throws {
    var buffer = [CChar](repeating: 0, count: 32)
    let modern = SmcReadKey("CHTE", &buffer, 32) == 0
    var failures = [String]()
    func write(_ key: String, _ value: String) -> Bool { SmcWriteKey(key, value) == 0 }
    if modern {
        if !write("CHTE", enabled ? "00000000" : "01000000") { failures.append("CHTE") }
        if enabled || failures.isEmpty {
            if !write("CHIE", enabled ? "00" : "08") && !write("CH0J", enabled ? "00" : "01") {
                failures.append("CHIE/CH0J")
            }
        }
    } else {
        for (key, value) in [("CH0B", enabled ? "00" : "02"), ("CH0C", enabled ? "00" : "02"), ("CH0I", enabled ? "00" : "01")] {
            if !write(key, value) { failures.append(key); if !enabled { break } }
        }
    }
    if !failures.isEmpty { throw AppError.message("SMC 写入失败：" + failures.joined(separator: ", ")) }
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
    return servePowerCommands(uid: uid, token: token, path: "/var/run/batterytool-\(uid).sock", apply: writeCharging)
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
