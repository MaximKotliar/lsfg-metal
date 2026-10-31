import Foundation
import Metal

/// Compute pipelines built from the translated metallib (see scripts/translate-shaders.sh).
public struct LSFGKernels: @unchecked Sendable {
    public struct Kernel: @unchecked Sendable {
        public let pipeline: MTLComputePipelineState
        public let threadgroupSize: MTLSize
    }

    public let device: MTLDevice
    public let kernels: [UInt32: Kernel]

    /// Cache folder written by the translate script, keyed by the DLL's hash.
    public static func cacheDirectory(forDLL dll: URL) throws -> URL {
        let hash = try Data(contentsOf: dll, options: .mappedIfSafe).sha256Hex.prefix(16)
        let base = ProcessInfo.processInfo.environment["LSFG_CACHE"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/lsfg-metal")
        return base.appending(path: String(hash))
    }

    /// Builds pipelines for `ids`, or for every kernel in the library when `ids` is nil.
    public init(cacheDirectory: URL, ids: Set<UInt32>? = nil,
                device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw LSFGError.metal("no Metal device") }
        self.device = device
        let library = try device.makeLibrary(URL: cacheDirectory.appending(path: "lsfg.metallib"))

        var groups: [UInt32: MTLSize] = [:]
        let groupsText = try String(contentsOf: cacheDirectory.appending(path: "groups.txt"), encoding: .utf8)
        for line in groupsText.split(separator: "\n") {
            let f = line.split(separator: " ").compactMap { Int($0) }
            if f.count == 4 { groups[UInt32(f[0])] = MTLSize(width: f[1], height: f[2], depth: f[3]) }
        }

        var kernels: [UInt32: Kernel] = [:]
        for name in library.functionNames where name.hasPrefix("lsfg_") {
            guard let id = UInt32(name.dropFirst(5)), ids?.contains(id) ?? true else { continue }
            guard let fn = library.makeFunction(name: name), let size = groups[id] else {
                throw LSFGError.metal("kernel \(id) has no function or threadgroup size")
            }
            let pipeline = try device.makeComputePipelineState(function: fn)
            guard size.width * size.height * size.depth <= pipeline.maxTotalThreadsPerThreadgroup else {
                throw LSFGError.metal("kernel \(id): threadgroup \(size) exceeds \(pipeline.maxTotalThreadsPerThreadgroup)")
            }
            kernels[id] = Kernel(pipeline: pipeline, threadgroupSize: size)
        }
        if let ids, let missing = ids.subtracting(kernels.keys).min() {
            throw LSFGError.metal("kernel \(missing) missing from library; re-run scripts/translate-shaders.sh")
        }
        self.kernels = kernels
    }

    public subscript(id: UInt32) -> Kernel { kernels[id]! }
}

public enum LSFGError: Error, CustomStringConvertible {
    case metal(String)
    case image(String)

    public var description: String {
        switch self {
        case let .metal(m): "Metal: \(m)"
        case let .image(m): "image: \(m)"
        }
    }
}
