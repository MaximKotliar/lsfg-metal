import AVFoundation
import Foundation
import LSFGCore
import Metal

/// Real-content evaluation: take a recording of a game, keep every other frame as the
/// "real" stream, generate the frame in between with LSFG, and score it against the frame
/// the game actually rendered there.
struct EvalOptions {
    var start: Double = 0       // seconds into the video
    var count = 121             // decoded frames to use
    var maxWidth = 1920         // downscale wider sources
    var settings = LSFGSettings()
    var samples: URL?           // write example triplets here
    var cutThreshold = 40.0     // mean abs diff (0-255) above which a pair counts as a scene cut
}

struct EvalFrame {
    let image: FrameIO.Image
    let time: Double
}

// MARK: - Loading

func loadFrames(from url: URL, options: EvalOptions) async throws -> [EvalFrame] {
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
        let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return try files.prefix(options.count).enumerated().map { i, f in
            EvalFrame(image: fit(try FrameIO.load(f), maxWidth: options.maxWidth), time: Double(i))
        }
    }

    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
        throw LSFGError.image("no video track in \(url.lastPathComponent)")
    }
    let reader = try AVAssetReader(asset: asset)
    let duration = try await asset.load(.duration)
    reader.timeRange = CMTimeRange(start: CMTime(seconds: options.start, preferredTimescale: 600), end: duration)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? LSFGError.image("cannot read video") }

    var frames: [EvalFrame] = []
    while frames.count < options.count, let sample = output.copyNextSampleBuffer() {
        guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), stride = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            let row = base + y * stride
            for x in 0..<w {
                let s = x * 4, d = (y * w + x) * 4
                rgba[d] = row[s + 2]; rgba[d + 1] = row[s + 1]; rgba[d + 2] = row[s]
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        frames.append(EvalFrame(image: fit(FrameIO.Image(width: w, height: h, rgba: rgba), maxWidth: options.maxWidth), time: t))
    }
    return frames
}

private func fit(_ img: FrameIO.Image, maxWidth: Int) -> FrameIO.Image {
    guard img.width > maxWidth else { return img }
    let h = (img.height * maxWidth / img.width) & ~1
    return FrameIO.resized(img, width: maxWidth, height: h)
}

/// Drops frames identical to the previous one (the game didn't render a new frame).
func dropDuplicates(_ frames: [EvalFrame]) -> (frames: [EvalFrame], dropped: Int) {
    var out: [EvalFrame] = []
    for f in frames {
        if let last = out.last, meanAbsDiff(last.image, f.image) < 0.05 { continue }
        out.append(f)
    }
    return (out, frames.count - out.count)
}

// MARK: - Metrics

func meanAbsDiff(_ a: FrameIO.Image, _ b: FrameIO.Image) -> Double {
    var sum = 0
    for i in stride(from: 0, to: a.rgba.count, by: 4) {
        sum += abs(Int(a.rgba[i]) - Int(b.rgba[i])) + abs(Int(a.rgba[i + 1]) - Int(b.rgba[i + 1]))
            + abs(Int(a.rgba[i + 2]) - Int(b.rgba[i + 2]))
    }
    return Double(sum) / Double(a.rgba.count / 4 * 3)
}

func psnr(_ a: FrameIO.Image, _ b: FrameIO.Image) -> Double {
    var se = 0.0
    for i in 0..<a.rgba.count where i % 4 != 3 {
        let d = Double(a.rgba[i]) - Double(b.rgba[i]); se += d * d
    }
    let mse = se / Double(a.rgba.count / 4 * 3)
    return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
}

/// Mean SSIM on luma over 8×8 blocks (simple, stride 4).
func ssim(_ a: FrameIO.Image, _ b: FrameIO.Image) -> Double {
    let w = a.width, h = a.height
    func luma(_ img: FrameIO.Image) -> [Double] {
        (0..<(w * h)).map { i in
            0.299 * Double(img.rgba[i * 4]) + 0.587 * Double(img.rgba[i * 4 + 1]) + 0.114 * Double(img.rgba[i * 4 + 2])
        }
    }
    let la = luma(a), lb = luma(b)
    let c1: Double = (0.01 * 255) * (0.01 * 255), c2: Double = (0.03 * 255) * (0.03 * 255)
    var total = 0.0, n = 0
    for y in stride(from: 0, to: h - 8, by: 4) {
        for x in stride(from: 0, to: w - 8, by: 4) {
            var ma = 0.0, mb = 0.0
            for dy in 0..<8 { for dx in 0..<8 { let i = (y + dy) * w + x + dx; ma += la[i]; mb += lb[i] } }
            ma /= 64; mb /= 64
            var va = 0.0, vb = 0.0, cov = 0.0
            for dy in 0..<8 { for dx in 0..<8 {
                let i = (y + dy) * w + x + dx
                let da = la[i] - ma, db = lb[i] - mb
                va += da * da; vb += db * db; cov += da * db
            } }
            va /= 63; vb /= 63; cov /= 63
            total += ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2))
            n += 1
        }
    }
    return total / Double(n)
}

func blend(_ a: FrameIO.Image, _ b: FrameIO.Image) -> FrameIO.Image {
    FrameIO.Image(width: a.width, height: a.height,
                  rgba: zip(a.rgba, b.rgba).map { UInt8((Int($0) + Int($1) + 1) / 2) })
}

/// Truth | generated | blend, side by side.
func sideBySide(_ images: [FrameIO.Image]) -> FrameIO.Image {
    let w = images[0].width, h = images[0].height, total = w * images.count
    var out = [UInt8](repeating: 0, count: total * h * 4)
    for (k, img) in images.enumerated() {
        for y in 0..<h {
            let src = y * w * 4, dst = (y * total + k * w) * 4
            out.replaceSubrange(dst..<(dst + w * 4), with: img.rgba[src..<(src + w * 4)])
        }
    }
    return FrameIO.Image(width: total, height: h, rgba: out)
}

// MARK: - Evaluation

struct Score {
    let index: Int
    let motion: Double         // mean abs diff between the two real frames
    let psnrGen: Double, psnrBlend: Double, psnrRepeat: Double
    let ssimGen: Double, ssimBlend: Double
}

func evaluate(frames: [EvalFrame], options: EvalOptions, kernels: LSFGKernels) throws -> [Score] {
    let first = frames[0].image
    var settings = options.settings
    settings.multiplier = 2
    var lsfg = try LSFG31(width: first.width, height: first.height, settings: settings, kernels: kernels)
    guard let queue = kernels.device.makeCommandQueue() else { throw LSFGError.metal("queue") }

    var scores: [Score] = []
    var skippedCuts = 0
    defer { if skippedCuts > 0 { print("  skipped \(skippedCuts) frame pairs that span a scene cut") } }
    // Real stream: even frames. Odd frames are ground truth for the frame in between.
    for k in stride(from: 0, to: frames.count, by: 2) {
        FrameIO.upload(frames[k].image, to: lsfg.nextInput)
        guard let cb = queue.makeCommandBuffer() else { throw LSFGError.metal("cb") }
        try lsfg.encode(into: cb, generate: k >= 2)
        cb.commit()
        cb.waitUntilCompleted()
        if let e = cb.error { throw e }
        guard k >= 4 else { continue } // let the 3-slot history fill with real frames first

        let prev = frames[k - 2].image, next = frames[k].image, truth = frames[k - 1].image
        // A scene cut between the two real frames can't be interpolated by anything; skip it.
        let motion = meanAbsDiff(prev, next)
        if motion > options.cutThreshold { skippedCuts += 1; continue }
        let gen = FrameIO.download(lsfg.outputs[0])
        let mix = blend(prev, next)
        scores.append(Score(index: k - 1, motion: motion,
                            psnrGen: psnr(gen, truth), psnrBlend: psnr(mix, truth), psnrRepeat: psnr(prev, truth),
                            ssimGen: ssim(gen, truth), ssimBlend: ssim(mix, truth)))

        if let dir = options.samples {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FrameIO.save(sideBySide([truth, gen, mix]), to: dir.appending(path: String(format: "%04d.png", k - 1)))
        }
    }
    return scores
}

func report(_ scores: [Score], label: String) {
    func med(_ v: [Double]) -> Double { let s = v.sorted(); return s[s.count / 2] }
    func mean(_ v: [Double]) -> Double { v.reduce(0, +) / Double(v.count) }
    let wins = scores.filter { $0.psnrGen > $0.psnrBlend }.count
    let ssimWins = scores.filter { $0.ssimGen > $0.ssimBlend }.count
    print(String(format: "%@: %d in-between frames", label as NSString, scores.count))
    print(String(format: "  PSNR  median: LSFG %.2f dB, blend %.2f dB, repeat %.2f dB (mean LSFG %.2f, blend %.2f)",
                 med(scores.map(\.psnrGen)), med(scores.map(\.psnrBlend)), med(scores.map(\.psnrRepeat)),
                 mean(scores.map(\.psnrGen)), mean(scores.map(\.psnrBlend))))
    print(String(format: "  SSIM  median: LSFG %.4f, blend %.4f", med(scores.map(\.ssimGen)), med(scores.map(\.ssimBlend))))
    print("  LSFG beats blend on \(wins)/\(scores.count) frames (PSNR), \(ssimWins)/\(scores.count) (SSIM)")
    let worst = scores.sorted { ($0.psnrGen - $0.psnrBlend) < ($1.psnrGen - $1.psnrBlend) }.prefix(3)
    print("  worst vs blend: " + worst.map { String(format: "#%d (%.1f vs %.1f dB, motion %.1f)",
                                                    $0.index, $0.psnrGen, $0.psnrBlend, $0.motion) }.joined(separator: ", "))
}
