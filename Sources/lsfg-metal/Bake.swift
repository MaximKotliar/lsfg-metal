import Foundation
import LSFGCore
import Synchronization

/// Builds the pre-baked kernel library: every LSFG 3.1 shader with its weights lifted out into
/// zeroed function constants, translated (SPIRV-Cross) and compiled once. The output contains no
/// weights; at runtime LSFGKernels(bakedDirectory:dll:ids:) fills them in from the user's DLL.
func bake(dll: URL, out: URL) throws -> Int {
    func tool(_ name: String) -> URL? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].map { URL(fileURLWithPath: $0).appending(path: name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    guard let spirvCross = tool("spirv-cross") else { throw LSFGError.metal("spirv-cross not found (brew install spirv-cross)") }
    let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
    func run(_ exe: URL, _ args: [String]) throws {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw LSFGError.metal("\(exe.lastPathComponent) failed: \(String(decoding: output, as: UTF8.self).suffix(400))")
        }
    }

    let spirv = try LSFGShaderLibrary(dll: dll).spirv
    let ids = [true, false].flatMap { fp16 in [true, false].flatMap { LSFG31Shaders.allIDs(fp16: fp16, performance: $0) } }
    let unique = Array(Set(ids)).sorted()
    let work = out.appending(path: "work")
    try? FileManager.default.removeItem(at: work)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

    let entries = Mutex<[String: BakedManifest.Entry]>([:])
    let failure = Mutex<String?>(nil)
    DispatchQueue.concurrentPerform(iterations: unique.count) { i in
        let id = unique[i]
        do {
            guard let code = spirv[id], let size = SPIRVConstants.localSize(code) else { throw LSFGError.metal("shader \(id) missing") }
            let lifted = try SPIRVConstants.lift(code)
            let spv = work.appending(path: "\(id).spv"), msl = work.appending(path: "\(id).metal")
            try lifted.skeleton.write(to: spv)
            try run(spirvCross, [spv.path, "--msl", "--msl-version", "30000", "--msl-decoration-binding",
                                 "--rename-entry-point", "main", "lsfg_\(id)", "comp", "--output", msl.path])
            try SPIRVConstants.fixUpMSL(String(contentsOf: msl, encoding: .utf8)).write(to: msl, atomically: true, encoding: .utf8)
            try run(xcrun, ["-sdk", "macosx", "metal", "-std=metal3.0", "-O3", "-c", msl.path,
                            "-o", work.appending(path: "\(id).air").path])
            entries.withLock {
                $0[String(id)] = BakedManifest.Entry(hash: lifted.structureHash, constants: lifted.constants.count,
                                                     group: [size.0, size.1, size.2])
            }
        } catch {
            failure.withLock { $0 = "\(error)" }
        }
    }
    if let message = failure.withLock({ $0 }) { throw LSFGError.metal(message) }

    try run(xcrun, ["-sdk", "macosx", "metallib"] + unique.map { work.appending(path: "\($0).air").path }
                   + ["-o", out.appending(path: LSFGKernels.skeletonLibraryName).path])
    var manifest = BakedManifest()
    manifest.kernels = entries.withLock { $0 }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(to: out.appending(path: LSFGKernels.manifestName))
    try FileManager.default.removeItem(at: work)
    return unique.count
}

/// Builds the pre-baked DXBC kernel library (Lossless Scaling's upscalers: LS1, FSR, CAS, bicubic, ids given) the
/// same way, from DXBC: each float immediate is replaced with a unique sentinel, dxbc-spirv translates the shader,
/// and the sentinels in the lifted constants say which immediate each function constant comes from. The output holds
/// no weights; at runtime DXBCConstants.constants reads them from the user's DLL. Needs dxbc_compiler (dxbc-spirv).
func bakeDXBC(dll: URL, out: URL, ids: [UInt32], dxbcCompiler: URL) throws -> Int {
    guard let spirvCross = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].map({ URL(fileURLWithPath: $0).appending(path: "spirv-cross") })
        .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
        throw LSFGError.metal("spirv-cross not found (brew install spirv-cross)")
    }
    let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
    func run(_ exe: URL, _ args: [String]) throws {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw LSFGError.metal("\(exe.lastPathComponent) failed: \(String(decoding: output, as: UTF8.self).suffix(400))")
        }
    }

    let shaders = Dictionary(uniqueKeysWithValues: try LSFGShaderLibrary(dll: dll).entries.map { ($0.resourceID, $0.shader) })
    let work = out.appending(path: "work-dxbc")
    try? FileManager.default.removeItem(at: work)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

    let entries = Mutex<[String: BakedManifest.Entry]>([:])
    let failure = Mutex<String?>(nil)
    DispatchQueue.concurrentPerform(iterations: ids.count) { n in
        let id = ids[n]
        do {
            guard let shader = shaders[id], let group = shader.threadGroupSize else { throw LSFGError.metal("DXBC shader \(id) missing") }
            let dxbc = shader.bytes
            let size = (Int(group.0), Int(group.1), Int(group.2))
            let immediates = try DXBCConstants.immediates(dxbc)
            guard immediates.count <= DXBCConstants.maxSentinels else { throw LSFGError.metal("shader \(id): too many immediates") }
            let sentinels = work.appending(path: "\(id).dxbc"), spv = work.appending(path: "\(id).spv")
            try DXBCConstants.withSentinels(dxbc).write(to: sentinels)
            try run(dxbcCompiler, [sentinels.path, "--spv", spv.path])
            let code = try Data(contentsOf: spv)
            let lifted = try SPIRVConstants.lift(code, moveComposites: false)
            var seen = Set<Int>()
            let slots = try lifted.constants.map { c -> BakedManifest.Slot in
                if let i = DXBCConstants.sentinelIndex(c.value), i < immediates.count {
                    guard seen.insert(i).inserted else { throw LSFGError.metal("shader \(id): immediate \(i) became two constants") }
                    return BakedManifest.Slot(i: i, half: c.kind == .half)
                }
                guard abs(c.value) < 4000 else { throw LSFGError.metal("shader \(id): constant \(c.value) looks like a mangled sentinel") }
                return BakedManifest.Slot(fixed: c.bits, half: c.kind == .half)
            }
            let skeleton = work.appending(path: "\(id).skeleton.spv"), msl = work.appending(path: "\(id).metal")
            try lifted.skeleton.write(to: skeleton)
            try run(spirvCross, [skeleton.path, "--msl", "--msl-version", "30000", "--msl-decoration-binding",
                                 "--rename-entry-point", "main", "lsfg_\(id)", "comp", "--output", msl.path])
            // SPIRV-Cross marks DXBC's precise-multiply helpers optnone; they stay exact without it, and inline.
            var source = SPIRVConstants.fixUpMSL(try String(contentsOf: msl, encoding: .utf8))
                .replacingOccurrences(of: "[[clang::optnone]] ", with: "")
            // dxbc-spirv declares the group size with LocalSizeId; SPIRV-Cross then uses gl_WorkGroupSize undeclared
            if source.contains("gl_WorkGroupSize"), !source.contains("gl_WorkGroupSize =") {
                source = source.replacingOccurrences(of: "using namespace metal;",
                    with: "using namespace metal;\nconstant uint3 gl_WorkGroupSize = uint3(\(size.0)u, \(size.1)u, \(size.2)u);")
            }
            try source.write(to: msl, atomically: true, encoding: .utf8)
            try run(xcrun, ["-sdk", "macosx", "metal", "-std=metal3.0", "-O3", "-c", msl.path,
                            "-o", work.appending(path: "\(id).air").path])
            let hash = try DXBCConstants.structureHash(dxbc)
            entries.withLock {
                $0[String(id)] = BakedManifest.Entry(hash: hash, constants: slots.count,
                                                     group: [size.0, size.1, size.2], slots: slots)
            }
        } catch {
            failure.withLock { $0 = "\(error)" }
        }
    }
    if let message = failure.withLock({ $0 }) { throw LSFGError.metal(message) }

    try run(xcrun, ["-sdk", "macosx", "metallib"] + ids.map { work.appending(path: "\($0).air").path }
                   + ["-o", out.appending(path: LSFGKernels.dxbcSkeletonLibraryName).path])
    var manifest = BakedManifest()
    manifest.kernels = entries.withLock { $0 }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(to: out.appending(path: LSFGKernels.dxbcManifestName))
    if ProcessInfo.processInfo.environment["LSFG_BAKE_KEEP"] == nil { try FileManager.default.removeItem(at: work) }   // keep: to inspect
    return ids.count
}
