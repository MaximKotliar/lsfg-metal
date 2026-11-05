import CryptoKit
import Foundation

/// The numbers in a DXBC shader: the 32-bit immediates of its float instructions (weights, biases, coefficients).
///
/// Lossless Scaling's upscalers (LS1, FSR, CAS, bicubic) are DXBC with their weights written into the code as
/// immediates. Baking (on a developer's Mac, with dxbc-spirv) replaces each with a unique sentinel, translates, and
/// lifts the constants into Metal function constants; the sentinels say which immediate became which constant. At
/// run time the same immediates are read from the user's own Lossless.dll with this reader, no tools needed, and
/// supplied as the function constants.
public enum DXBCConstants {
    /// One float immediate: its byte offset in the DXBC container, and its index among the shader's candidates.
    public struct Immediate: Sendable, Equatable {
        public let offset: Int
        public let opcode: UInt32
    }

    /// Opcodes whose immediates are floats (SM4/5): add, div, dp2-4, eq, exp, frc, ge, log, lt, mad, min, max, mul,
    /// ne, round_*, rsq, sqrt, sincos, deriv_rtx/rty, rcp. Others (integer ops, moves, declarations) keep theirs.
    static let floatOpcodes: Set<UInt32> = [0, 11, 12, 14, 15, 16, 17, 24, 25, 26, 29, 47, 49, 50, 51, 52, 56, 57,
                                            64, 65, 66, 67, 68, 75, 77, 129]

    /// The shader's float immediates, in program order.
    public static func immediates(_ dxbc: Data) throws -> [Immediate] {
        let (base, words) = try program(dxbc)
        var out: [Immediate] = []
        var pc = 2
        while pc < words.count {
            let token = words[pc]
            let opcode = token & 0x7FF
            var length = Int((token >> 24) & 0x7F)
            if opcode == 53 { length = pc + 1 < words.count ? Int(words[pc + 1]) : 0 }   // customdata
            guard length > 0, pc + length <= words.count else { throw ParseError.malformed("DXBC instruction at dword \(pc)") }
            if floatOpcodes.contains(opcode) {
                var p = pc + 1
                var extended = token >> 31 != 0
                while extended, p < pc + length { extended = words[p] >> 31 != 0; p += 1 }   // extended opcode tokens
                var found: [Int] = []
                while p < pc + length {
                    guard let next = operand(words, at: p, end: pc + length, immediates: &found) else {
                        throw ParseError.malformed("DXBC operand at dword \(p)")
                    }
                    p = next
                }
                guard p == pc + length else { throw ParseError.malformed("DXBC instruction at dword \(pc) overruns") }
                out += found.map { Immediate(offset: base + 4 * $0, opcode: opcode) }
            }
            pc += length
        }
        return out
    }

    /// Parses one operand at `p`; appends the dword index of each 32-bit immediate component. Returns the next dword.
    private static func operand(_ w: [UInt32], at start: Int, end: Int, immediates: inout [Int]) -> Int? {
        var p = start
        guard p < end else { return nil }
        let token = w[p]
        p += 1
        var extended = token >> 31 != 0
        while extended { guard p < end else { return nil }; extended = w[p] >> 31 != 0; p += 1 }
        let components: Int
        switch token & 3 {
        case 0: components = 0
        case 1: components = 1
        case 2: components = 4
        default: return nil   // N components: not used by compute shaders
        }
        let type = (token >> 12) & 0xFF
        let dimension = Int((token >> 20) & 3)
        for i in 0..<dimension {
            switch (token >> (22 + 3 * UInt32(i))) & 7 {
            case 0: p += 1                                   // immediate32
            case 1: p += 2                                   // immediate64
            case 2:                                          // relative
                var ignored: [Int] = []
                guard let next = operand(w, at: p, end: end, immediates: &ignored) else { return nil }
                p = next
            case 3:                                          // immediate32 + relative
                p += 1
                var ignored: [Int] = []
                guard let next = operand(w, at: p, end: end, immediates: &ignored) else { return nil }
                p = next
            case 4:                                          // immediate64 + relative
                p += 2
                var ignored: [Int] = []
                guard let next = operand(w, at: p, end: end, immediates: &ignored) else { return nil }
                p = next
            default: return nil
            }
        }
        switch type {
        case 4:   // immediate32
            immediates += (0..<components).map { p + $0 }
            p += components
        case 5:   // immediate64
            p += 2 * components
        default:
            break
        }
        return p <= end ? p : nil
    }

    /// The raw bits of each float immediate.
    public static func values(_ dxbc: Data) throws -> [UInt32] {
        try immediates(dxbc).map { word(dxbc, $0.offset) }
    }

    static func word(_ data: Data, _ offset: Int) -> UInt32 {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }

    /// Identifies the shader's structure: its program with every float immediate zeroed. Weights from another DLL
    /// apply to a baked skeleton only when this matches.
    public static func structureHash(_ dxbc: Data) throws -> String {
        let (base, words) = try program(dxbc)
        var zeroed = words
        for i in try immediates(dxbc) { zeroed[(i.offset - base) / 4] = 0 }
        let digest = zeroed.withUnsafeBufferPointer { SHA256.hash(data: Data(buffer: $0)) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The shader with immediate j replaced by `sentinel(j)`, for baking.
    public static func withSentinels(_ dxbc: Data) throws -> Data {
        var out = dxbc
        for (j, i) in try immediates(dxbc).enumerated() {
            var bits = sentinel(j).bitPattern
            withUnsafeBytes(of: &bits) { out.replaceSubrange(i.offset..<(i.offset + 4), with: $0) }
        }
        return out
    }

    /// Unique values, exact in fp16 and fp32 and far from the small constants compilers add (0, 0.5, 1, 2…):
    /// 4096 + 4j for j < 1024, then 8192 + 8j, 16384 + 16j, 32768 + 32j.
    public static func sentinel(_ j: Int) -> Float {
        let binade = j / 1024, step = Float(4 << binade)
        return Float(4096 << binade) + step * Float(j % 1024)
    }

    public static let maxSentinels = 4 * 1024 - 1   // 32768 + 32 * 1023 = 65504, fp16's largest

    /// The immediate a sentinel value stands for, or nil.
    public static func sentinelIndex(_ value: Float) -> Int? {
        guard value >= 4096, value <= 65504 else { return nil }
        let binade = Int(log2(value / 4096).rounded(.down))
        let step = Float(4 << binade), base = Float(4096 << binade)
        let k = (value - base) / step
        guard k == k.rounded(), k >= 0, k < 1024 else { return nil }
        return binade * 1024 + Int(k)
    }

    /// A baked DXBC kernel's function constants, from the user's own shader: its immediates where the slots say,
    /// converted to fp16 where the kernel takes fp16. Throws if the shader's structure isn't the baked one.
    public static func constants(_ dxbc: Data, entry: BakedManifest.Entry) throws -> [SPIRVConstants.Constant] {
        guard let slots = entry.slots, slots.count == entry.constants else { throw ParseError.malformed("not a DXBC kernel") }
        guard try structureHash(dxbc) == entry.hash else { throw ParseError.malformed("shader structure differs") }
        let values = try values(dxbc)
        return try slots.map { slot in
            let bits: UInt32
            if let i = slot.i {
                guard i < values.count else { throw ParseError.malformed("immediate \(i) out of range") }
                bits = slot.half ? UInt32(halfTowardZero(Float(bitPattern: values[i]))) : values[i]
            } else {
                bits = slot.fixed ?? 0
            }
            return SPIRVConstants.Constant(kind: slot.half ? .half : .float, bits: bits)
        }
    }

    /// fp32 -> fp16 bits exactly as dxbc-spirv converts min-precision immediates (util::f32tof16): truncated,
    /// too large -> the largest finite value, too small -> 0. (Bits, not Float16: that type is arm64-only.)
    public static func halfTowardZero(_ f: Float) -> UInt16 {
        let u = f.bitPattern
        let exp32 = (u & 0x7F80_0000) >> 23, frc32 = u & 0x007F_FFFF, sign = (u & 0x8000_0000) >> 16
        var exp16: UInt32, frc16: UInt32
        if exp32 > 142 {
            if exp32 == 0xFF { exp16 = 0x1F; frc16 = frc32 >> 13; if frc32 != 0 { frc16 |= 0x200 } }
            else { exp16 = 0x1E; frc16 = 0x3FF }
        } else if exp32 < 113 {
            exp16 = 0
            frc16 = exp32 >= 103 ? (0x0400 | (frc32 >> 13)) >> (113 - exp32) : 0
        } else {
            exp16 = exp32 - 112; frc16 = frc32 >> 13
        }
        return UInt16(sign | (exp16 << 10) | frc16)
    }

    /// The SHEX/SHDR chunk as dwords, and the byte offset of its first dword in the container.
    static func program(_ dxbc: Data) throws -> (Int, [UInt32]) {
        guard dxbc.count >= 32, dxbc.starts(with: Array("DXBC".utf8)) else { throw ParseError.badMagic("DXBC") }
        let chunkCount = Int(word(dxbc, 28))
        for i in 0..<chunkCount {
            let off = Int(word(dxbc, 32 + 4 * i))
            guard off + 8 <= dxbc.count else { break }
            let tag = String(decoding: dxbc[dxbc.startIndex + off..<dxbc.startIndex + off + 4], as: UTF8.self)
            guard tag == "SHEX" || tag == "SHDR" else { continue }
            let size = Int(word(dxbc, off + 4))
            let start = off + 8
            guard start + size <= dxbc.count else { throw ParseError.malformed("DXBC chunk size") }
            let count = min(size / 4, Int(word(dxbc, start + 4)))
            return (start, (0..<count).map { word(dxbc, start + 4 * $0) })
        }
        throw ParseError.malformed("no SHEX/SHDR chunk")
    }
}
