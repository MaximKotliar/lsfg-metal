import Foundation
import Metal
import Synchronization

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

    private init(device: MTLDevice, kernels: [UInt32: Kernel]) {
        self.device = device
        self.kernels = kernels
    }

    public subscript(id: UInt32) -> Kernel { kernels[id]! }
}

// MARK: - Pre-baked kernels

/// Describes a pre-baked skeleton library: per kernel, the structure hash it was baked from, how
/// many constants it takes and its threadgroup size. Contains no weights.
public struct BakedManifest: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public var hash: String
        public var constants: Int
        public var group: [Int]

        public init(hash: String, constants: Int, group: [Int]) {
            self.hash = hash
            self.constants = constants
            self.group = group
        }
    }

    public var version = 1
    public var kernels: [String: Entry] = [:]

    public init() {}
}

extension LSFGKernels {
    public static let skeletonLibraryName = "lsfg-skeleton.metallib"
    public static let manifestName = "manifest.json"

    public static func loadManifest(_ bakedDirectory: URL) throws -> BakedManifest {
        try JSONDecoder().decode(BakedManifest.self, from: Data(contentsOf: bakedDirectory.appending(path: manifestName)))
    }

    /// The kernels in `ids` whose structure in the user's DLL differs from the baked skeleton
    /// (for example after a Lossless Scaling update). Empty means the baked library fits.
    public static func bakedMismatches(bakedDirectory: URL, dll: URL, ids: Set<UInt32>) throws -> [UInt32] {
        let manifest = try loadManifest(bakedDirectory)
        let spirv = try LSFGShaderLibrary(dll: dll).spirv
        return try ids.sorted().filter { id in
            guard let entry = manifest.kernels[String(id)], let code = spirv[id] else { return true }
            return try SPIRVConstants.lift(code).structureHash != entry.hash
        }
    }

    /// Builds pipelines from the pre-baked skeleton, specialized with the constants (weights)
    /// from the user's own Lossless.dll. Throws if any kernel's structure doesn't match.
    public init(bakedDirectory: URL, dll: URL, ids: Set<UInt32>,
                device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw LSFGError.metal("no Metal device") }
        let manifest = try Self.loadManifest(bakedDirectory)
        let library = try device.makeLibrary(URL: bakedDirectory.appending(path: Self.skeletonLibraryName))
        let spirv = try LSFGShaderLibrary(dll: dll).spirv

        // Lift first (cheap, serial), so a mismatch fails before any compiling.
        var jobs: [(id: UInt32, constants: [SPIRVConstants.Constant], group: MTLSize)] = []
        for id in ids.sorted() {
            guard let entry = manifest.kernels[String(id)], let code = spirv[id] else {
                throw LSFGError.metal("kernel \(id) is missing from the baked library or the DLL")
            }
            let lifted = try SPIRVConstants.lift(code)
            guard lifted.structureHash == entry.hash, lifted.constants.count == entry.constants, entry.group.count == 3 else {
                throw LSFGError.metal("kernel \(id) in this Lossless.dll doesn't match the baked library")
            }
            jobs.append((id, lifted.constants, MTLSize(width: entry.group[0], height: entry.group[1], depth: entry.group[2])))
        }

        // Specializing compiles each kernel for this GPU; do them in parallel. Metal caches the
        // results, so later launches are quick.
        let built = Mutex<[UInt32: Kernel]>([:])
        let failure = Mutex<String?>(nil)
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
            let job = jobs[i]
            let values = MTLFunctionConstantValues()
            for (k, c) in job.constants.enumerated() {
                switch c.kind {
                case .half: var bits = UInt16(c.bits); values.setConstantValue(&bits, type: .half, index: k)
                case .float: var bits = c.bits; values.setConstantValue(&bits, type: .float, index: k)
                }
            }
            do {
                let fn = try library.makeFunction(name: "lsfg_\(job.id)", constantValues: values)
                let pipeline = try device.makeComputePipelineState(function: fn)
                built.withLock { $0[job.id] = Kernel(pipeline: pipeline, threadgroupSize: job.group) }
            } catch {
                failure.withLock { $0 = "kernel \(job.id): \(error)" }
            }
        }
        if let message = failure.withLock({ $0 }) { throw LSFGError.metal(message) }
        self.init(device: device, kernels: built.withLock { $0 })
    }
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
