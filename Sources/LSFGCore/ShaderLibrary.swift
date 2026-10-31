import CryptoKit
import Foundation

/// The LSFG compute shaders, read from the user's Lossless.dll at runtime.
/// Nothing here is ever written into the repository.
public struct LSFGShaderLibrary: Sendable {
    public struct Entry: Sendable {
        public let resourceID: UInt32
        public let sha256: String
        public let shader: DXBCShader
    }

    public let entries: [Entry]

    public init(dll: URL) throws {
        let file = try Data(contentsOf: dll, options: .mappedIfSafe)
        entries = try PEFile.resources(in: file).compactMap { res in
            guard case .id(PEFile.rtRCData) = res.type, case let .id(id) = res.name,
                  res.data.starts(with: Array("DXBC".utf8)) else { return nil }
            return Entry(resourceID: id, sha256: res.data.sha256Hex, shader: try DXBCShader(res.data))
        }.sorted { $0.resourceID < $1.resourceID }
    }
}

extension Data {
    var sha256Hex: String { SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined() }
}
