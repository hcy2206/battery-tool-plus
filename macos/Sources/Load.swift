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
/// Workers run at user-initiated QoS so Apple Silicon schedules them on performance cores.
func runLoadWorker(kind: String, intensity: Double, threads: Int) -> Int32 {
    guard intensity > 0, intensity <= 1, threads >= 1, threads <= ProcessInfo.processInfo.activeProcessorCount else { return 1 }
    if kind == "cpu" {
        for index in 0..<threads {
            DispatchQueue.global(qos: .userInitiated).async {
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
            guard let buffer = device.makeBuffer(length: gpuLoadThreads * MemoryLayout<Float>.size, options: .storageModeShared)
            else { return 2 }
            let pipeline = try makeLoadPipeline(device: device)
            DispatchQueue.global(qos: .userInitiated).async {
                runGPULoad(queue: queue, pipeline: pipeline, buffer: buffer, intensity: intensity)
            }
        } catch { return 2 }
    } else { return 1 }
    return waitForLoadLease()
}

/// A batch must keep the GPU busy for tens of milliseconds: a 65536-thread dispatch finished in
/// ~0.6 ms on an M2 Max, so submission latency and the sleep floor dominated and the GPU sat at
/// ~24 % while asked for 80 %. Two command buffers are committed back to back so the GPU does not
/// idle while the CPU encodes, and the duty cycle is taken from the GPU's own timestamps.
let gpuLoadThreads = 1 << 22
func runGPULoad(queue: MTLCommandQueue, pipeline: MTLComputePipelineState, buffer: MTLBuffer, intensity: Double) -> Never {
    let threadgroup = MTLSize(width: min(256, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1)
    while true {
        autoreleasepool {
            var commands = [MTLCommandBuffer]()
            for _ in 0..<2 {
                guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { exit(2) }
                encoder.setComputePipelineState(pipeline)
                encoder.setBuffer(buffer, offset: 0, index: 0)
                encoder.dispatchThreads(MTLSize(width: gpuLoadThreads, height: 1, depth: 1), threadsPerThreadgroup: threadgroup)
                encoder.endEncoding()
                command.commit()
                commands.append(command)
            }
            let submitted = ProcessInfo.processInfo.systemUptime
            for command in commands {
                command.waitUntilCompleted()
                if command.status == .error { exit(2) }
            }
            let busy = commands[1].gpuEndTime - commands[0].gpuStartTime
            let elapsed = busy > 0 ? busy : ProcessInfo.processInfo.systemUptime - submitted
            if intensity < 1 { Thread.sleep(forTimeInterval: elapsed * (1 - intensity) / intensity) }
        }
    }
}

/// Shared by real load workers and a computation-free lifecycle probe.
/// The controller heartbeats every 2 s; the lease covers its worst-case blocking
/// on the power service (two requests with 2 s send/receive timeouts each).
let loadLeaseMilliseconds: Int32 = 15000
func waitForLoadLease(milliseconds: Int32 = loadLeaseMilliseconds) -> Int32 {
    while true {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
        guard poll(&descriptor, 1, milliseconds) > 0 else { return 0 }
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
