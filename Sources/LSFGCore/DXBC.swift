import Foundation

/// A parsed DXBC container (Shader Model 4/5 bytecode).
public struct DXBCShader: Sendable {
    public struct Binding: Sendable {
        public enum Kind: UInt32, Sendable {
            case cbuffer = 0, tbuffer, texture, sampler, uavTyped, structured, uavStructured
            case byteAddress, uavByteAddress, uavAppend, uavConsume, uavStructuredWithCounter
            case unknown = 0xFFFF_FFFF
        }

        public let name: String
        public let kind: Kind
        public let dimension: UInt32
        public let bindPoint: UInt32
        public let bindCount: UInt32
        public let space: UInt32

        /// HLSL register letter for this binding: b, t, s or u.
        public var registerClass: Character {
            switch kind {
            case .cbuffer: "b"
            case .sampler: "s"
            case .tbuffer, .texture, .structured, .byteAddress: "t"
            default: "u"
            }
        }
    }

    public struct ConstantBuffer: Sendable {
        public struct Variable: Sendable {
            public let name: String
            public let offset: UInt32
            public let size: UInt32
        }
        public let name: String
        public let size: UInt32
        public let variables: [Variable]
    }

    public let bytes: Data
    /// Chunk FourCC → contents.
    public let chunks: [(tag: String, data: Data)]
    public let programType: UInt16
    public let major: UInt8
    public let minor: UInt8
    public let bindings: [Binding]
    public let constantBuffers: [ConstantBuffer]
    public let threadGroupSize: (x: UInt32, y: UInt32, z: UInt32)?
    public let tempRegisters: UInt32
    public let instructionCount: Int
    /// Size of the immediate constant buffer in 16-byte vectors (0 if none).
    public let immediateConstantVectors: Int

    public var isCompute: Bool { programType == 5 }

    public init(_ bytes: Data) throws {
        let r = ByteReader(bytes)
        guard try r.fourCC(0) == "DXBC" else { throw ParseError.badMagic("DXBC") }
        let total = try r.int(24)
        guard total <= bytes.count else { throw ParseError.malformed("DXBC size \(total) > \(bytes.count)") }
        let chunkCount = try r.int(28)
        var chunks: [(String, Data)] = []
        for i in 0..<chunkCount {
            let off = try r.int(32 + 4 * i)
            let tag = try r.fourCC(off)
            let size = try r.int(off + 4)
            chunks.append((tag, try r.bytes(off + 8, size)))
        }
        self.bytes = bytes
        self.chunks = chunks

        guard let code = chunks.first(where: { $0.0 == "SHEX" || $0.0 == "SHDR" })?.1 else {
            throw ParseError.malformed("no SHEX/SHDR chunk")
        }
        let program = try Self.parseProgram(code)
        programType = program.type
        major = program.major
        minor = program.minor
        threadGroupSize = program.threadGroup
        tempRegisters = program.temps
        instructionCount = program.instructions
        immediateConstantVectors = program.icbVectors

        if let rdef = chunks.first(where: { $0.0 == "RDEF" })?.1 {
            (bindings, constantBuffers) = try Self.parseRDEF(rdef, sm51: program.major == 5 && program.minor == 1)
        } else {
            (bindings, constantBuffers) = ([], [])
        }
    }

    private static func parseProgram(_ code: Data) throws
        -> (type: UInt16, major: UInt8, minor: UInt8, threadGroup: (UInt32, UInt32, UInt32)?,
            temps: UInt32, instructions: Int, icbVectors: Int)
    {
        let r = ByteReader(code)
        let version = try r.u32(0)
        let lengthDwords = min(try r.int(4), code.count / 4)
        var threadGroup: (UInt32, UInt32, UInt32)?
        var temps: UInt32 = 0
        var instructions = 0
        var icbVectors = 0

        var pc = 2
        while pc < lengthDwords {
            let token = try r.u32(pc * 4)
            let opcode = token & 0x7FF
            var length = Int((token >> 24) & 0x7F)
            if opcode == 53 { // customdata: length is the next dword
                length = try r.int((pc + 1) * 4)
                let dataClass = token >> 11
                if dataClass == 3 { icbVectors += max(0, length - 2) / 4 } // immediate constant buffer
            }
            guard length > 0 else { throw ParseError.malformed("zero-length instruction at dword \(pc)") }
            switch opcode {
            case 155: threadGroup = (try r.u32((pc + 1) * 4), try r.u32((pc + 2) * 4), try r.u32((pc + 3) * 4))
            case 104: temps = try r.u32((pc + 1) * 4)
            case 53: break
            default: if opcode < 89 || opcode > 106 { instructions += 1 } // skip most dcl_* opcodes
            }
            pc += length
        }
        return (UInt16(version >> 16), UInt8((version >> 4) & 0xF), UInt8(version & 0xF),
                threadGroup, temps, instructions, icbVectors)
    }

    private static func parseRDEF(_ rdef: Data, sm51: Bool) throws -> ([Binding], [ConstantBuffer]) {
        let r = ByteReader(rdef)
        let cbCount = try r.int(0), cbOffset = try r.int(4)
        let bindCount = try r.int(8), bindOffset = try r.int(12)
        let bindStride = sm51 ? 40 : 32
        let rdefMajor = try r.u8(17)
        let varStride = sm51 || rdefMajor >= 5 ? 40 : 24

        let bindings = try (0..<bindCount).map { i -> Binding in
            let b = bindOffset + bindStride * i
            return Binding(name: try r.cString(try r.int(b)),
                           kind: Binding.Kind(rawValue: try r.u32(b + 4)) ?? .unknown,
                           dimension: try r.u32(b + 12),
                           bindPoint: try r.u32(b + 20),
                           bindCount: try r.u32(b + 24),
                           space: sm51 ? try r.u32(b + 32) : 0)
        }
        let cbuffers = try (0..<cbCount).map { i -> ConstantBuffer in
            let c = cbOffset + 24 * i
            let varCount = try r.int(c + 4), varOffset = try r.int(c + 8)
            let vars = try (0..<varCount).map { v -> ConstantBuffer.Variable in
                let o = varOffset + varStride * v
                return .init(name: try r.cString(try r.int(o)), offset: try r.u32(o + 4), size: try r.u32(o + 8))
            }
            return ConstantBuffer(name: try r.cString(try r.int(c)), size: try r.u32(c + 12), variables: vars)
        }
        return (bindings, cbuffers)
    }
}
