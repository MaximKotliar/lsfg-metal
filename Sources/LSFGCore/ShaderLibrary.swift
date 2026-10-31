import CryptoKit
import Foundation

/// The shaders in the user's Lossless.dll, read at runtime.
/// Nothing here is ever written into the repository.
///
/// The DLL's RCDATA resources hold two sets:
/// - DXBC (SM5.0) compute shaders, IDs 101–302: upscalers and older LSFG versions.
/// - SPIR-V compute shaders, IDs 303–400: LSFG 3.1, used by lsfg-metal.
public struct LSFGShaderLibrary: Sendable {
    public struct Entry: Sendable {
        public let resourceID: UInt32
        public let sha256: String
        public let shader: DXBCShader
    }

    public let entries: [Entry]
    /// SPIR-V resources by ID.
    public let spirv: [UInt32: Data]

    static let spirvMagic: [UInt8] = [0x03, 0x02, 0x23, 0x07]

    public init(dll: URL) throws {
        let file = try Data(contentsOf: dll, options: .mappedIfSafe)
        var entries: [Entry] = []
        var spirv: [UInt32: Data] = [:]
        for res in try PEFile.resources(in: file) {
            guard case .id(PEFile.rtRCData) = res.type, case let .id(id) = res.name else { continue }
            if res.data.starts(with: Array("DXBC".utf8)) {
                entries.append(Entry(resourceID: id, sha256: res.data.sha256Hex, shader: try DXBCShader(res.data)))
            } else if res.data.starts(with: Self.spirvMagic) {
                spirv[id] = res.data
            }
        }
        self.entries = entries.sorted { $0.resourceID < $1.resourceID }
        self.spirv = spirv
    }
}

extension Data {
    var sha256Hex: String { SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined() }
}
