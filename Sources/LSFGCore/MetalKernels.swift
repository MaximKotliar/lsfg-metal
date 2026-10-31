import Foundation
import Metal

/// Compute pipelines built from the translated LSFG metallib.
public struct LSFGKernels: @unchecked Sendable {
    public let device: MTLDevice
    public let library: MTLLibrary
    public let pipelines: [UInt32: MTLComputePipelineState]

    /// Cache folder that `scripts/translate-shaders.sh` writes, keyed by the DLL's hash.
    public static func defaultLibraryURL(forDLL dll: URL) throws -> URL {
        let hash = try Data(contentsOf: dll, options: .mappedIfSafe).sha256Hex.prefix(16)
        let base = ProcessInfo.processInfo.environment["LSFG_CACHE"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/lsfg-metal")
        return base.appending(path: "\(hash)/lsfg.metallib")
    }

    public init(libraryURL: URL, device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw ParseError.malformed("no Metal device") }
        self.device = device
        library = try device.makeLibrary(URL: libraryURL)
        var pipelines: [UInt32: MTLComputePipelineState] = [:]
        for name in library.functionNames where name.hasPrefix("lsfg_") {
            guard let id = UInt32(name.dropFirst(5)), let fn = library.makeFunction(name: name) else { continue }
            pipelines[id] = try device.makeComputePipelineState(function: fn)
        }
        self.pipelines = pipelines
    }
}
