import Foundation
import LSFGCore
import Metal

/// Runs every mode, flow scale and multiplier through the recorded-plan path (`encode`) and the
/// direct path (`encodeUnplanned`) side by side, and compares the generated frames byte for byte.
/// Returns how many configurations differ.
func runPlanCheck(prev: FrameIO.Image, next: FrameIO.Image, kernels: LSFGKernels) throws -> Int {
    let (w, h) = (640, 360)
    let device = kernels.device
    guard let queue = device.makeCommandQueue() else { throw LSFGError.metal("queue") }
    func source(_ img: FrameIO.Image) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { throw LSFGError.metal("texture") }
        FrameIO.upload(FrameIO.resized(img, width: w, height: h), to: t)
        return t
    }
    let sources = [try source(prev), try source(next)]
    func bytes(_ t: MTLTexture) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h * 4)
        t.getBytes(&out, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return out
    }
    var failures = 0
    for perf in [false, true] { for flow in [Float(1.0), 0.5] { for mult in [2, 3, 4] {
        var s = LSFGSettings()
        s.performance = perf; s.flowScale = flow; s.multiplier = mult
        var planned = try LSFG31(width: w, height: h, settings: s, kernels: kernels)
        var direct = try LSFG31(width: w, height: h, settings: s, kernels: kernels)
        var same = true, compared = 0
        for i in 0..<14 { // more than two %6 cycles: warm-up frames (no generation), then generating ones
            let generate = i >= 2
            guard let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { throw LSFGError.metal("cb") }
            blit.copy(from: sources[i % 2], to: planned.nextInput)
            blit.copy(from: sources[i % 2], to: direct.nextInput)
            blit.endEncoding()
            try planned.encode(into: cb, generate: generate)
            try direct.encodeUnplanned(into: cb, generate: generate)
            cb.commit()
            cb.waitUntilCompleted()
            guard generate else { continue }
            for j in 0..<planned.outputs.count where bytes(planned.outputs[j]) != bytes(direct.outputs[j]) { same = false }
            compared += planned.outputs.count
        }
        if !same { failures += 1 }
        print("\(perf ? "perf" : "qual") flow \(flow) \(mult)x: \(same ? "identical" : "DIFFERENT") (\(compared) frames)")
    } } }
    return failures
}
