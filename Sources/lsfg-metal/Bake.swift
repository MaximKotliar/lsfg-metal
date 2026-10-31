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
