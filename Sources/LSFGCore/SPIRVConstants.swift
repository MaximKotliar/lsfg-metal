import CryptoKit
import Foundation

/// Splits an LSFG SPIR-V shader into structure and numbers.
///
/// Every floating-point scalar constant (weights, biases, coefficients) becomes a specialization
/// constant with value 0 and `SpecId = k`. Vectors and matrices built from them are rebuilt with
/// OpCompositeConstruct at the top of the entry function (Metal can't initialize program-scope
/// constants from function constants); once Metal specializes the function they fold back to
/// literals. The result ("skeleton") translates to Metal with function constants and contains
/// no weights; at runtime the same constants, read from the user's own Lossless.dll, are supplied
/// as MTLFunctionConstantValues and Metal folds them back in.
public enum SPIRVConstants {
    public struct Constant: Sendable, Equatable {
        public enum Kind: Sendable { case half, float }
        public let kind: Kind
        public let bits: UInt32 // raw IEEE bits (low 16 for half)
    }

    public struct Lifted: Sendable {
        public let skeleton: Data
        /// In SpecId order.
        public let constants: [Constant]
        /// Hash of the shader with all float constant values zeroed: identifies the network's
        /// structure, so weights from another DLL only apply when it matches.
        public let structureHash: String
    }

    private struct Instruction {
        var opcode: UInt32
        var words: [UInt32] // full instruction including the opcode word
    }

    private static let opTypeFloat: UInt32 = 22, opConstant: UInt32 = 43, opConstantComposite: UInt32 = 44
    private static let opSpecConstant: UInt32 = 50, opDecorate: UInt32 = 71
    private static let opFunction: UInt32 = 54, opLabel: UInt32 = 248, opVariable: UInt32 = 59, opCompositeConstruct: UInt32 = 80
    private static let decorationSpecId: UInt32 = 1

    public static func lift(_ spirv: Data) throws -> Lifted {
        let words: [UInt32] = spirv.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
        guard words.count > 5, words[0] == 0x0723_0203 else { throw ParseError.badMagic("SPIR-V") }
        var header = Array(words[0..<5])
        var instructions: [Instruction] = []
        var i = 5
        while i < words.count {
            let count = Int(words[i] >> 16)
            guard count > 0, i + count <= words.count else { throw ParseError.malformed("SPIR-V instruction at word \(i)") }
            instructions.append(Instruction(opcode: words[i] & 0xFFFF, words: Array(words[i..<(i + count)])))
            i += count
        }

        var floatWidth: [UInt32: UInt32] = [:] // type id -> 16 / 32
        var constants: [Constant] = []
        var specIds: [(id: UInt32, k: UInt32)] = []
        var specResults = Set<UInt32>()
        var hashed = instructions // copy with values zeroed, for the structure hash
        var moved: [Instruction] = [] // composites rebuilt inside the function, in definition order
        var movedIndices = Set<Int>()

        for n in instructions.indices {
            let ins = instructions[n]
            switch ins.opcode {
            case opTypeFloat:
                floatWidth[ins.words[1]] = ins.words[2]
            case opConstant where floatWidth[ins.words[1]] != nil:
                let width = floatWidth[ins.words[1]]!
                let result = ins.words[2]
                constants.append(Constant(kind: width == 16 ? .half : .float,
                                          bits: width == 16 ? ins.words[3] & 0xFFFF : ins.words[3]))
                specIds.append((result, UInt32(specIds.count)))
                specResults.insert(result)
                instructions[n].opcode = opSpecConstant
                instructions[n].words[0] = (UInt32(ins.words.count) << 16) | opSpecConstant
                instructions[n].words[3] = 0
                hashed[n].words[3] = 0
            case opConstantComposite where ins.words[3...].contains(where: specResults.contains):
                // Same layout as OpCompositeConstruct: [op, type, result, constituents...].
                specResults.insert(ins.words[2])
                var construct = ins
                construct.opcode = opCompositeConstruct
                construct.words[0] = (UInt32(ins.words.count) << 16) | opCompositeConstruct
                moved.append(construct)
                movedIndices.insert(n)
            default:
                break
            }
        }

        // Move the composites into the entry function: after its first label and local variables.
        guard instructions.count(where: { $0.opcode == opFunction }) == 1 else {
            throw ParseError.malformed("expected one function in the shader")
        }
        instructions = instructions.enumerated().filter { !movedIndices.contains($0.offset) }.map(\.element)
        guard let function = instructions.firstIndex(where: { $0.opcode == opFunction }),
              let label = instructions[function...].firstIndex(where: { $0.opcode == opLabel }) else {
            throw ParseError.malformed("shader function has no body")
        }
        var insertAt = label + 1
        while insertAt < instructions.count, instructions[insertAt].opcode == opVariable { insertAt += 1 }
        instructions.insert(contentsOf: moved, at: insertAt)

        // SpecId decorations go with the other annotations, before the first type declaration.
        let firstType = instructions.firstIndex { (19...39).contains($0.opcode) } ?? instructions.count
        let decorations = specIds.map { Instruction(opcode: opDecorate, words: [(4 << 16) | opDecorate, $0.id, decorationSpecId, $0.k]) }
        instructions.insert(contentsOf: decorations, at: firstType)

        let out = header + instructions.flatMap(\.words)
        header[0] = words[0] // header unchanged; ids already bounded
        let skeleton = out.withUnsafeBufferPointer { Data(buffer: $0) }
        let hashWords = Array(words[0..<5]) + hashed.flatMap(\.words)
        let digest = hashWords.withUnsafeBufferPointer { SHA256.hash(data: Data(buffer: $0)) }
        return Lifted(skeleton: skeleton, constants: constants,
                      structureHash: digest.map { String(format: "%02x", $0) }.joined())
    }
}

extension SPIRVConstants {
    /// `OpExecutionMode %main LocalSize x y z`, read straight from the SPIR-V words.
    public static func localSize(_ spirv: Data) -> (Int, Int, Int)? {
        let words: [UInt32] = spirv.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
        var i = 5
        while i < words.count {
            let count = Int(words[i] >> 16), opcode = words[i] & 0xFFFF
            guard count > 0 else { return nil }
            if opcode == 16, count >= 6, words[i + 2] == 17 { return (Int(words[i + 3]), Int(words[i + 4]), Int(words[i + 5])) }
            i += count
        }
        return nil
    }

    /// Fixes up SPIRV-Cross output for lsfg-metal:
    /// - function constants are used directly (SPIRV-Cross wraps each in a second program-scope
    ///   constant with a default, which keeps Metal from folding them as well);
    /// - lsfg-vk's Vulkan binding ranges move into Metal's tables: samplers 16+ -> 0+, images 32+ -> 0+.
    public static func fixUpMSL(_ source: String) -> String {
        var s = source.replacing(
            /constant (\w+) (\w+)_tmp \[\[function_constant\((\d+)\)\]\];\nconstant \w+ \w+ = is_function_constant_defined\(\w+_tmp\) \? \w+_tmp : [^;]+;/
        ) { m in "constant \(m.output.1) \(m.output.2) [[function_constant(\(m.output.3))]];" }
        s = s.replacing(/\[\[(sampler|texture)\((\d+)\)\]\]/) { m in
            let n = Int(m.output.2) ?? 0
            let shift = m.output.1 == "sampler" ? 16 : 32
            return n >= shift ? "[[\(m.output.1)(\(n - shift))]]" : String(m.output.0)
        }
        return s
    }
}
