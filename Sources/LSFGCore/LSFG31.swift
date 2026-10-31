import Foundation
import Metal

/// User-facing LSFG settings (same meaning as lsfg-vk's conf.toml).
public struct LSFGSettings: Sendable {
    /// Total frames shown per real frame. 2 means one generated frame between each real pair.
    public var multiplier: Int = 2
    /// Resolution of the motion-estimation pyramid relative to the frame, 0.25...1.0.
    public var flowScale: Float = 1.0
    public var hdr: Bool = false
    /// Use the DLL's fp16 shader variants (recommended on Apple GPUs).
    public var fp16: Bool = true

    public init() {}

    public var generationCount: Int { max(1, multiplier - 1) }
}

/// Resource IDs of the LSFG 3.1 (quality) shaders in Lossless.dll.
///
/// The layout of this table, the pass graph and the constant-buffer contents below follow
/// lsfg-vk's framegen/v3.1 (MIT License, Copyright (c) 2025 lsfg-vk,
/// https://github.com/PancakeTAS/lsfg-vk at its MIT-licensed revisions).
public enum LSFG31Shaders {
    /// Base indices; the DLL stores fp16 variants at base + 49 and fp32 at base + 98.
    static let base: [String: UInt32] = [
        "mipmaps": 255, "generate": 256,
        "alpha0": 267, "alpha1": 268, "alpha2": 269, "alpha3": 270,
        "beta0": 275, "beta1": 276, "beta2": 277, "beta3": 278, "beta4": 279,
        "gamma0": 257, "gamma1": 259, "gamma2": 260, "gamma3": 261, "gamma4": 262,
        "delta0": 257, "delta1": 263, "delta2": 264, "delta3": 265, "delta4": 266,
        "delta5": 258, "delta6": 271, "delta7": 272, "delta8": 273, "delta9": 274,
    ]

    static func id(_ name: String, fp16: Bool) -> UInt32 { base[name]! + (fp16 ? 49 : 98) }

    public static func allIDs(fp16: Bool) -> Set<UInt32> { Set(base.keys.map { id($0, fp16: fp16) }) }
}

/// LSFG 3.1 frame generation on Metal.
///
/// Usage: write each real frame into `nextInput`, then call `encode(into:)`.
/// After the command buffer completes, `outputs[i]` holds generated frame i
/// between the previous and the current real frame.
public struct LSFG31 {
    public let width: Int
    public let height: Int
    public let settings: LSFGSettings
    public let device: MTLDevice
    /// Frames between previous and current real frame, earliest first.
    public let outputs: [MTLTexture]
    public private(set) var frameIndex: UInt64 = 0

    private let kernels: LSFGKernels
    private let inputs: [MTLTexture]
    private let mips: [MTLTexture]
    private let alpha: [Alpha]
    private let beta: Beta
    private let gamma: [Gamma]
    private let delta: [Delta]
    private let samplerBlack: MTLSamplerState
    private let samplerWhite: MTLSamplerState
    private let samplerEdge: MTLSamplerState
    private let dummy: MTLTexture

    private struct Alpha { let temp1: [MTLTexture], temp2: [MTLTexture], temp3: [MTLTexture], out: [[MTLTexture]] }
    private struct Beta { let temp1: [MTLTexture], temp2: [MTLTexture], out: [MTLTexture] }
    private struct Gamma { let temp1: [MTLTexture], temp2: [MTLTexture], out: MTLTexture }
    private struct Delta { let temp1: [MTLTexture], temp2: [MTLTexture], out1: MTLTexture, out2: MTLTexture }

    /// The texture the next real frame must be written into before `encode`.
    public var nextInput: MTLTexture { inputs[Int(frameIndex % 2)] }

    public init(width: Int, height: Int, format: MTLPixelFormat = .rgba8Unorm,
                settings: LSFGSettings = .init(), kernels: LSFGKernels) throws {
        self.width = width
        self.height = height
        self.settings = settings
        self.kernels = kernels
        let device = kernels.device
        self.device = device

        func tex(_ w: Int, _ h: Int, _ f: MTLPixelFormat = .rgba8Unorm, shared: Bool = false) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: max(1, w), height: max(1, h),
                                                             mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = shared ? .shared : .private
            guard let t = device.makeTexture(descriptor: d) else { throw LSFGError.metal("texture \(w)x\(h) \(f)") }
            return t
        }
        func texs(_ n: Int, _ w: Int, _ h: Int, _ f: MTLPixelFormat = .rgba8Unorm) throws -> [MTLTexture] {
            try (0..<n).map { _ in try tex(w, h, f) }
        }

        inputs = try (0..<2).map { _ in try tex(width, height, format, shared: true) }
        outputs = try (0..<settings.generationCount).map { _ in try tex(width, height, format, shared: true) }
        dummy = try tex(1, 1)

        // Motion-estimation pyramid: input / (1 / flowScale), as lsfg-vk computes it.
        let invScale = 1 / settings.flowScale
        let flowW = Int(Float(width) / invScale), flowH = Int(Float(height) / invScale)
        mips = try (0..<7).map { try tex(flowW >> $0, flowH >> $0, .r8Unorm) }

        let alpha = try mips.map { mip in
            let hw = (mip.width + 1) >> 1, hh = (mip.height + 1) >> 1
            let qw = (hw + 1) >> 1, qh = (hh + 1) >> 1
            return Alpha(temp1: try texs(2, hw, hh), temp2: try texs(2, hw, hh), temp3: try texs(4, qw, qh),
                         out: try (0..<3).map { _ in try texs(4, qw, qh) })
        }

        self.alpha = alpha
        let bw = alpha[0].out[0][0].width, bh = alpha[0].out[0][0].height
        beta = Beta(temp1: try texs(2, bw, bh), temp2: try texs(2, bw, bh),
                    out: try (0..<6).map { try tex(bw >> $0, bh >> $0, .r8Unorm) })

        gamma = try (0..<7).map { i in
            let e = alpha[6 - i].out[0][0]
            return Gamma(temp1: try texs(4, e.width, e.height), temp2: try texs(4, e.width, e.height),
                         out: try tex(e.width, e.height, .rgba16Float))
        }
        delta = try (4..<7).map { i in
            let e = alpha[6 - i].out[0][0]
            return Delta(temp1: try texs(4, e.width, e.height), temp2: try texs(4, e.width, e.height),
                         out1: try tex(e.width, e.height, .rgba16Float), out2: try tex(e.width, e.height, .rgba16Float))
        }

        func sampler(_ mode: MTLSamplerAddressMode, _ border: MTLSamplerBorderColor) throws -> MTLSamplerState {
            let d = MTLSamplerDescriptor()
            d.minFilter = .linear
            d.magFilter = .linear
            d.mipFilter = .linear
            d.sAddressMode = mode
            d.tAddressMode = mode
            d.rAddressMode = mode
            d.borderColor = border
            guard let s = device.makeSamplerState(descriptor: d) else { throw LSFGError.metal("sampler") }
            return s
        }
        samplerBlack = try sampler(.clampToBorderColor, .transparentBlack)
        samplerWhite = try sampler(.clampToBorderColor, .opaqueWhite)
        samplerEdge = try sampler(.clampToEdge, .transparentBlack)
    }

    // MARK: - Encoding

    /// The 48-byte constant buffer shared by all LSFG 3.1 shaders.
    private func constants(timestamp: Float, firstIter: Bool = false, firstIterS: Bool = false) -> [UInt32] {
        [0, 0,                                  // inputOffset
         firstIter ? 1 : 0, firstIterS ? 1 : 0,
         settings.hdr ? 2 : 0,                  // advancedColorKind
         settings.hdr ? 1 : 0,                  // hdrSupport
         (1 / settings.flowScale).bitPattern,   // resolutionInvScale
         timestamp.bitPattern,
         Float(0.5).bitPattern,                 // uiThreshold
         0, 0, 0]
    }

    private struct Encoder {
        let enc: MTLComputeCommandEncoder
        let kernels: LSFGKernels
        let fp16: Bool
        let dummy: MTLTexture

        func dispatch(_ name: String, constants: [UInt32]? = nil, samplers: [MTLSamplerState],
                      inputs: [MTLTexture?], outputs: [MTLTexture], groups: (Int, Int)) {
            precondition(inputs.count <= 16 && outputs.count <= 15, "binding table overflow in \(name)")
            let k = kernels[LSFG31Shaders.id(name, fp16: fp16)]
            enc.label = name
            enc.setComputePipelineState(k.pipeline)
            if var c = constants { enc.setBytes(&c, length: c.count * 4, index: 0) }
            for (i, s) in samplers.enumerated() { enc.setSamplerState(s, index: i) }
            for (i, t) in inputs.enumerated() { enc.setTexture(t ?? dummy, index: i) }
            for (i, t) in outputs.enumerated() { enc.setTexture(t, index: 16 + i) }
            enc.dispatchThreadgroups(MTLSize(width: groups.0, height: groups.1, depth: 1),
                                     threadsPerThreadgroup: k.threadgroupSize)
        }
    }

    private func opt(_ t: [MTLTexture]) -> [MTLTexture?] { t.map { $0 } }

    private static func groups(_ t: MTLTexture, _ shift: Int) -> (Int, Int) {
        let m = (1 << shift) - 1
        return ((t.width + m) >> shift, (t.height + m) >> shift)
    }

    /// Encodes one real frame (already written to `nextInput`).
    /// With `generate: false` only the analysis passes run, which is enough to warm up history.
    public mutating func encode(into commandBuffer: MTLCommandBuffer, generate: Bool = true) throws {
        guard let enc = commandBuffer.makeComputeCommandEncoder() else { throw LSFGError.metal("compute encoder") }
        let e = Encoder(enc: enc, kernels: kernels, fp16: settings.fp16, dummy: dummy)
        let fc = Int(frameIndex % 6) // 6 covers both the %2 and %3 rotations

        // 1. Pyramid and per-level features for the new frame.
        e.dispatch("mipmaps", constants: constants(timestamp: 0), samplers: [samplerBlack],
                   inputs: [inputs[fc % 2]], outputs: mips, groups: Self.groups(mips[0], 6))
        for level in (0..<7).reversed() {
            let a = alpha[level]
            e.dispatch("alpha0", samplers: [samplerBlack], inputs: [mips[level]],
                       outputs: a.temp1, groups: Self.groups(a.temp1[0], 3))
            e.dispatch("alpha1", samplers: [samplerBlack], inputs: a.temp1, outputs: a.temp2, groups: Self.groups(a.temp1[0], 3))
            e.dispatch("alpha2", samplers: [samplerBlack], inputs: a.temp2, outputs: a.temp3, groups: Self.groups(a.temp3[0], 3))
            e.dispatch("alpha3", samplers: [samplerBlack], inputs: a.temp3, outputs: a.out[fc % 3], groups: Self.groups(a.temp3[0], 3))
        }
        let a0 = alpha[0].out
        let i3 = fc % 3
        e.dispatch("beta0", samplers: [samplerWhite], inputs: a0[(i3 + 1) % 3] + a0[(i3 + 2) % 3] + a0[i3],
                   outputs: beta.temp1, groups: Self.groups(beta.temp1[0], 3))
        e.dispatch("beta1", samplers: [samplerBlack], inputs: beta.temp1, outputs: beta.temp2, groups: Self.groups(beta.temp1[0], 3))
        e.dispatch("beta2", samplers: [samplerBlack], inputs: beta.temp2, outputs: beta.temp1, groups: Self.groups(beta.temp1[0], 3))
        e.dispatch("beta3", samplers: [samplerBlack], inputs: beta.temp1, outputs: beta.temp2, groups: Self.groups(beta.temp1[0], 3))
        e.dispatch("beta4", constants: constants(timestamp: 0.5), samplers: [samplerBlack], inputs: beta.temp2,
                   outputs: beta.out, groups: Self.groups(beta.temp1[0], 5))

        // 2. One generation pass per in-between frame, coarse to fine.
        if generate {
            let n = settings.generationCount
            for pass in 0..<n {
                let t = Float(pass + 1) / Float(n + 1)
                for i in 0..<7 {
                    encodeGamma(e, i, fc: fc, timestamp: t)
                    if i >= 4 { encodeDelta(e, i, fc: fc, timestamp: t) }
                }
                let ordered = fc % 2 == 0 ? [inputs[1], inputs[0]] : [inputs[0], inputs[1]]
                e.dispatch("generate", constants: constants(timestamp: t), samplers: [samplerBlack, samplerEdge],
                           inputs: opt(ordered + [gamma[6].out, delta[2].out1, delta[2].out2]),
                           outputs: [outputs[pass]], groups: Self.groups(inputs[0], 4))
            }
        }
        enc.endEncoding()
        frameIndex += 1
    }

    private func encodeGamma(_ e: Encoder, _ i: Int, fc: Int, timestamp: Float) {
        let g = gamma[i], aOut = alpha[6 - i].out
        let prev: MTLTexture? = i == 0 ? nil : gamma[i - 1].out
        let c = constants(timestamp: timestamp, firstIter: prev == nil)
        let grid = Self.groups(g.temp1[0], 3)
        e.dispatch("gamma0", constants: c, samplers: [samplerWhite, samplerEdge],
                   inputs: opt(aOut[(fc + 2) % 3] + aOut[fc % 3]) + [prev], outputs: Array(g.temp1[0..<3]), groups: grid)
        e.dispatch("gamma1", samplers: [samplerBlack], inputs: Array(g.temp1[0..<3]), outputs: g.temp2, groups: grid)
        e.dispatch("gamma2", samplers: [samplerBlack], inputs: g.temp2, outputs: g.temp1, groups: grid)
        e.dispatch("gamma3", samplers: [samplerBlack], inputs: g.temp1, outputs: g.temp2, groups: grid)
        e.dispatch("gamma4", constants: c, samplers: [samplerBlack, samplerEdge],
                   inputs: opt(g.temp2) + [prev, beta.out[min(6 - i, 5)]], outputs: [g.out], groups: grid)
    }

    private func encodeDelta(_ e: Encoder, _ i: Int, fc: Int, timestamp: Float) {
        let k = i - 4
        let d = delta[k], aOut = alpha[6 - i].out
        let opt1: MTLTexture? = k == 0 ? nil : gamma[i - 1].out
        let opt2: MTLTexture? = k == 0 ? nil : delta[k - 1].out1
        let opt3: MTLTexture? = k == 0 ? nil : delta[k - 1].out2
        let c = constants(timestamp: timestamp, firstIterS: opt1 == nil)
        let grid = Self.groups(d.temp1[0], 3)
        let history = opt(aOut[(fc + 2) % 3] + aOut[fc % 3])
        e.dispatch("delta0", constants: c, samplers: [samplerWhite, samplerEdge],
                   inputs: history + [opt1], outputs: Array(d.temp1[0..<3]), groups: grid)
        e.dispatch("delta1", samplers: [samplerBlack], inputs: Array(d.temp1[0..<3]), outputs: d.temp2, groups: grid)
        e.dispatch("delta2", samplers: [samplerBlack], inputs: d.temp2, outputs: d.temp1, groups: grid)
        e.dispatch("delta3", samplers: [samplerBlack], inputs: d.temp1, outputs: d.temp2, groups: grid)
        e.dispatch("delta4", constants: c, samplers: [samplerBlack, samplerEdge],
                   inputs: opt(d.temp2) + [opt1, beta.out[6 - i]], outputs: [d.out1], groups: grid)
        e.dispatch("delta5", constants: c, samplers: [samplerWhite, samplerEdge],
                   inputs: history + [opt1, opt2], outputs: Array(d.temp2[0..<2]), groups: grid)
        e.dispatch("delta6", samplers: [samplerBlack], inputs: Array(d.temp2[0..<2]), outputs: Array(d.temp1[0..<2]), groups: grid)
        e.dispatch("delta7", samplers: [samplerBlack], inputs: Array(d.temp1[0..<2]), outputs: Array(d.temp2[0..<2]), groups: grid)
        e.dispatch("delta8", samplers: [samplerBlack], inputs: Array(d.temp2[0..<2]), outputs: Array(d.temp1[0..<2]), groups: grid)
        e.dispatch("delta9", constants: c, samplers: [samplerBlack, samplerEdge],
                   inputs: opt(Array(d.temp1[0..<2])) + [opt3], outputs: [d.out2], groups: grid)
    }
}
