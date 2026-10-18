import SwiftUI
import AppKit

@main struct IntegrationTests {
    @MainActor static func main() throws {
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--service-probe" {
            let path = CommandLine.arguments[2]
            exit(servePowerCommands(uid: getuid(), token: CommandLine.arguments[3], path: path, lease: 2) { enabled in
                let log = URL(fileURLWithPath: path + ".log")
                var text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                text += enabled ? "charge\n" : "discharge\n"
                try text.write(to: log, atomically: true, encoding: .utf8)
            })
        }
        if CommandLine.arguments.contains("--lease-probe") { exit(waitForLoadLease(milliseconds: 2000)) }
        // Exercise the exact worker heartbeat loop without running any compute work.
        let probe = Process()
        let input = Pipe()
        probe.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        probe.arguments = ["--lease-probe"]
        probe.standardInput = input
        try probe.run()
        try input.fileHandleForWriting.write(contentsOf: Data([10]))
        try input.fileHandleForWriting.close()
        probe.waitUntilExit()
        precondition(probe.terminationStatus == 0, "worker must exit when controller closes its pipe")
        let expired = Process()
        let idleInput = Pipe()
        expired.executableURL = probe.executableURL
        expired.arguments = ["--lease-probe"]
        expired.standardInput = idleInput
        let leaseStart = Date()
        try expired.run()
        expired.waitUntilExit()
        precondition(expired.terminationStatus == 0 && Date().timeIntervalSince(leaseStart) < 10,
                     "worker must exit after missing heartbeats")
        try idleInput.fileHandleForWriting.close()
        // Same socket transport and whitelist, backed by a temporary text log, never SMC.
        let socket = "/tmp/bt-test-" + UUID().uuidString + ".sock"
        defer { try? FileManager.default.removeItem(atPath: socket + ".log") }
        let token = UUID().uuidString
        let service = Process()
        service.executableURL = probe.executableURL
        service.arguments = ["--service-probe", socket, token]
        try service.run()
        let client = HardwareClient(token: token, socketPath: socket, expectedServer: getuid())
        var connected = false
        for _ in 0..<30 {
            do { try client.request("ping"); connected = true; break }
            catch { Thread.sleep(forTimeInterval: 0.05) }
        }
        precondition(connected, "test power transport did not start")
        let unauthorized = HardwareClient(token: UUID().uuidString, socketPath: socket, expectedServer: getuid())
        do { try unauthorized.request("discharge"); fatalError("bad token was accepted") } catch {}
        do { try client.request("arbitrary-shell-command"); fatalError("unknown command accepted") } catch {}
        let wrongServer = HardwareClient(token: token, socketPath: socket, expectedServer: 0)
        do { try wrongServer.request("ping"); fatalError("untrusted server UID accepted") } catch {}
        try client.request("discharge")
        service.waitUntilExit() // Simulate controller disappearance: no further heartbeats.
        precondition(service.terminationStatus == 0)
        let writes = try String(contentsOfFile: socket + ".log", encoding: .utf8)
        precondition(writes == "discharge\ncharge\n", "lease expiry must restore charging")
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = Controller(demo: true, storageDirectory: directory, startTimer: false)
        defer { model.shutdown() }
        precondition(model.errorMessage == nil, model.errorMessage ?? "")
        model.switchMode(.daily)
        precondition(model.mode == .daily && model.cpuLoad == 0 && model.gpuLoad == 0)
        let now = Date()
        precondition(model.start(plan: Plan(start: now, deadline: now.addingTimeInterval(3600), goal: .desk)))
        precondition(model.mode == .timed && model.cpuLoad == 50 && model.gpuLoad == 50)
        model.togglePause()
        precondition(model.cpuLoad == 0 && model.gpuLoad == 0)
        model.togglePause()
        precondition(model.cpuLoad == 50)
        model.settings.minimum = 200 // Invalid in-progress form must not block Stop.
        model.switchMode(.system)
        precondition(model.mode == .system && model.cpuLoad == 0)
        model.switchMode(.ready)
        precondition(model.mode == .ready && model.cpuLoad == 0)
        model.settings.minimum = 20
        precondition(!model.start(plan: Plan(start: now, deadline: now.addingTimeInterval(-1), goal: .desk)))
        model.errorMessage = nil
        precondition(model.start(plan: Plan(start: now, deadline: now.addingTimeInterval(3600), goal: .departure)))
        precondition(model.mode == .ready && model.cpuLoad == 0)
        let duplicate = Controller(demo: true, storageDirectory: directory, startTimer: false)
        precondition(!duplicate.start(plan: Plan(start: now, deadline: now.addingTimeInterval(3600), goal: .desk)))
        duplicate.shutdown()
        model.settings.recordHistory = true
        model.tick()
        model.refreshHistory()
        precondition(!model.graph.isEmpty)
        model.recommend()
        precondition(model.recommendation != nil)
        print("Native controller integration checks passed (demo only)")
        if CommandLine.arguments.count > 1 {
            let output = URL(fileURLWithPath: CommandLine.arguments[1])
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for (index, page) in ["控制台", "任务设置", "空闲推荐", "历史记录"].enumerated() {
                let view = ManagerView(model: model, page: page).frame(width: 1060, height: 900)
                    .background(Color(nsColor: .windowBackgroundColor))
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: 1060, height: 900)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("render failed") }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG failed") }
                try png.write(to: output.appendingPathComponent("page-\(index).png"))
            }
            print("Rendered four management views to \(output.path)")
        }
    }
}
