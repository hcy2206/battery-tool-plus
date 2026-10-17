import Foundation
import Metal
import Darwin

/// Compile the production shader without submitting any GPU work.
func makeLoadPipeline(device: MTLDevice) throws -> MTLComputePipelineState {
    let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void load(device float *output [[buffer(0)]], uint i [[thread_position_in_grid]]) {
            float x = float(i) * 0.00001f + 0.1f;
            for (uint n = 0; n < 256; ++n) { x = sin(x) + cos(x * 1.001f) + 1.01f; }
            output[i] = x;
        }
        """
    let library = try device.makeLibrary(source: source, options: nil)
    guard let function = library.makeFunction(name: "load") else { throw AppError.message("Metal 计算函数不可用") }
    return try device.makeComputePipelineState(function: function)
}

/// Worker lifetime is leased through stdin; no parent heartbeat means exit.
func runLoadWorker(kind: String, intensity: Double, threads: Int) -> Int32 {
    guard intensity > 0, intensity <= 1, threads >= 1, threads <= ProcessInfo.processInfo.activeProcessorCount else { return 1 }
    if kind == "cpu" {
        for index in 0..<threads {
            DispatchQueue.global(qos: .utility).async {
                var value = Double(index + 1)
                while true {
                    let start = ProcessInfo.processInfo.systemUptime
                    while ProcessInfo.processInfo.systemUptime - start < 0.1 * intensity {
                        for _ in 0..<1000 { value = sin(value) + cos(value * 1.001) + 1.01 }
                    }
                    // Observable result prevents dead-code elimination in optimized builds.
                    if !value.isFinite { exit(2) }
                    Thread.sleep(forTimeInterval: max(0.001, 0.1 * (1 - intensity)))
                }
            }
        }
    } else if kind == "gpu" {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return 2 }
        do {
            guard let buffer = device.makeBuffer(length: 65536 * MemoryLayout<Float>.size, options: .storageModeShared)
            else { return 2 }
            let pipeline = try makeLoadPipeline(device: device)
            DispatchQueue.global(qos: .utility).async {
                while true {
                    autoreleasepool {
                        let start = ProcessInfo.processInfo.systemUptime
                        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { exit(2) }
                        encoder.setComputePipelineState(pipeline)
                        encoder.setBuffer(buffer, offset: 0, index: 0)
                        encoder.dispatchThreads(MTLSize(width: 65536, height: 1, depth: 1),
                                                threadsPerThreadgroup: MTLSize(width: min(256, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
                        encoder.endEncoding()
                        command.commit()
                        command.waitUntilCompleted()
                        if command.status == .error { exit(2) }
                        let elapsed = ProcessInfo.processInfo.systemUptime - start
                        Thread.sleep(forTimeInterval: max(0.001, min(1, elapsed * (1 - intensity) / intensity)))
                    }
                }
            }
        } catch { return 2 }
    } else { return 1 }
    return waitForLoadLease()
}

/// Shared by real load workers and a computation-free lifecycle probe.
func waitForLoadLease() -> Int32 {
    while true {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
        guard poll(&descriptor, 1, 6000) > 0 else { return 0 }
        var buffer = [UInt8](repeating: 0, count: 64)
        guard read(STDIN_FILENO, &buffer, buffer.count) > 0 else { return 0 }
    }
}

final class LoadManager {
    private var children: [(Process, Pipe)] = []
    private var configuration = ""
    var running: Bool { !children.isEmpty }
    func update(cpu: Double, gpu: Double, threads: Int) throws {
        let key = "\(cpu):\(gpu):\(threads)"
        if key == configuration {
            for (process, input) in children {
                guard process.isRunning else { stop(); throw AppError.message("负载进程意外退出，任务已停止") }
                do { try input.fileHandleForWriting.write(contentsOf: Data([10])) }
                catch { stop(); throw error }
            }
            return
        }
        stop()
        do {
            for (kind, intensity) in [("cpu", cpu), ("gpu", gpu)] where intensity > 0 {
                let process = Process()
                let input = Pipe()
                process.executableURL = Bundle.main.executableURL
                process.arguments = ["--worker", kind, String(intensity / 100), String(threads)]
                process.standardInput = input
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                children.append((process, input))
                try input.fileHandleForWriting.write(contentsOf: Data([10]))
            }
            configuration = key
        } catch { stop(); throw error }
    }
    func stop() {
        for (process, input) in children {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        children.removeAll()
        configuration = ""
    }
    deinit { stop() }
}
