import Foundation
import LSFGCore
import Metal
import Synchronization

/// Sustained benchmark: feeds frames back to back (alternating two images, copied on the GPU
/// the way a presentation hook would), keeps several frames in flight, and measures
/// per-frame GPU time, CPU encode time and throughput.
struct BenchResult {
    let gpuMedian: Double, gpuP95: Double, cpuEncode: Double, throughputFPS: Double, memoryMB: Double, dispatches: Int
}

func runBench(prev: FrameIO.Image, next: FrameIO.Image, settings: LSFGSettings, kernels: LSFGKernels,
              frames: Int, inFlight: Int = 3) throws -> BenchResult {
    let device = kernels.device
    var lsfg = try LSFG31(width: prev.width, height: prev.height, settings: settings, kernels: kernels)
    guard let queue = device.makeCommandQueue() else { throw LSFGError.metal("queue") }

    // Source frames live on the GPU; each real frame is a GPU copy into the LSFG input.
    func source(_ img: FrameIO.Image) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: img.width, height: img.height, mipmapped: false)
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { throw LSFGError.metal("texture") }
        FrameIO.upload(img, to: t)
        return t
    }
    let sources = [try source(prev), try source(next)]

    let gpuTimes = Mutex<[Double]>([])
    let slots = DispatchSemaphore(value: inFlight)
    var cpuTimes: [Double] = []
    let warmup = 30
    var start = Date()

    for i in 0..<(warmup + frames) {
        if i == warmup { queue.makeCommandBuffer().map { $0.commit(); $0.waitUntilCompleted() }; start = Date() }
        slots.wait()
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { throw LSFGError.metal("cb") }
        blit.copy(from: sources[i % 2], to: lsfg.nextInput)
        blit.endEncoding()
        try lsfg.encode(into: cb, generate: true)
        let measured = i >= warmup
        cb.addCompletedHandler { cb in
            if measured { gpuTimes.withLock { $0.append((cb.gpuEndTime - cb.gpuStartTime) * 1000) } }
            slots.signal()
        }
        cb.commit()
        if measured { cpuTimes.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6) }
    }
    for _ in 0..<inFlight { slots.wait() } // drain: every frame has completed
    let wall = Date().timeIntervalSince(start)
    for _ in 0..<inFlight { slots.signal() } // libdispatch traps if a semaphore is freed below its start value

    let gpu = gpuTimes.withLock { $0 }.sorted()
    return BenchResult(gpuMedian: gpu[gpu.count / 2], gpuP95: gpu[gpu.count * 95 / 100],
                       cpuEncode: cpuTimes.sorted()[cpuTimes.count / 2],
                       throughputFPS: Double(frames) / wall,
                       memoryMB: Double(lsfg.memoryFootprint) / 1_048_576, dispatches: lsfg.dispatchesPerFrame)
}
