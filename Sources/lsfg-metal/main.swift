import Foundation
import LSFGCore

let usage = """
usage: lsfg-metal <command> [options]

commands:
  locate              find Lossless Scaling (Steam app \(LosslessInstall.steamAppID)) in CrossOver bottles
  inspect [--dll P]   list the LSFG compute shaders in Lossless.dll and their bindings
                      add --verbose for per-binding detail
  dump --out DIR      write the shaders as .dxbc files (keep DIR outside the repo)
  check               build a Metal pipeline for every translated kernel

environment:
  LSFG_BOTTLES  extra bottle folders to scan, colon-separated
  LSFG_DLL      path to Lossless.dll (skips the Steam lookup)
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func resolveDLL(_ args: [String]) -> URL {
    if let i = args.firstIndex(of: "--dll"), i + 1 < args.count { return URL(fileURLWithPath: args[i + 1]) }
    if let path = ProcessInfo.processInfo.environment["LSFG_DLL"] { return URL(fileURLWithPath: path) }
    guard let install = LosslessLocator.findAll().first else {
        fail("Lossless Scaling not found. Install it with Steam in a CrossOver bottle, or pass --dll.")
    }
    return install.dll
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "locate":
    let installs = LosslessLocator.findAll()
    if installs.isEmpty { fail("Lossless Scaling not found in: " + LosslessLocator.bottleRoots().map(\.path).joined(separator: ", ")) }
    for i in installs {
        print("bottle:   \(i.bottle.lastPathComponent)")
        print("dll:      \(i.dll.path)")
        print("buildid:  \(i.buildID ?? "?")\n")
    }

case "inspect":
    let dll = resolveDLL(args)
    let verbose = args.contains("--verbose")
    do {
        let lib = try LSFGShaderLibrary(dll: dll)
        print("\(lib.entries.count) DXBC shaders in \(dll.lastPathComponent)\n")
        print("id    sha256        type  group       temps  instr  icb   bindings")
        for e in lib.entries {
            let s = e.shader
            let group = s.threadGroupSize.map { "\($0.x)x\($0.y)x\($0.z)" } ?? "-"
            let binds = s.bindings.map { "\($0.registerClass)\($0.bindPoint)" + ($0.bindCount > 1 ? "[\($0.bindCount)]" : "") }
                .joined(separator: " ")
            let pad = { (v: String, n: Int) in v.padding(toLength: n, withPad: " ", startingAt: 0) }
            print(pad(String(e.resourceID), 6) + pad(String(e.sha256.prefix(12)), 14)
                  + pad(s.isCompute ? "cs" : "t\(s.programType)", 6) + pad("\(s.major).\(s.minor) \(group)", 12)
                  + pad(String(s.tempRegisters), 7) + pad(String(s.instructionCount), 7)
                  + pad(String(s.immediateConstantVectors), 6) + binds)
            if verbose {
                for b in s.bindings { print("        \(b.registerClass)\(b.bindPoint)  \(b.kind)  dim=\(b.dimension)  \(b.name)") }
                for cb in s.constantBuffers {
                    print("        cbuffer \(cb.name) (\(cb.size) B): " + cb.variables.map { "\($0.name)@\($0.offset)" }.joined(separator: ", "))
                }
            }
        }
    } catch {
        fail("failed to read \(dll.path): \(error)")
    }

case "dump":
    // Writes the user's own shaders to a local folder for offline translation.
    // Keep that folder outside the repo; never share its contents.
    guard let i = args.firstIndex(of: "--out"), i + 1 < args.count else { fail("dump needs --out DIR") }
    let out = URL(fileURLWithPath: args[i + 1])
    do {
        let lib = try LSFGShaderLibrary(dll: resolveDLL(args))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for e in lib.entries { try e.shader.bytes.write(to: out.appending(path: "\(e.resourceID).dxbc")) }
        print("wrote \(lib.entries.count) shaders to \(out.path)")
    } catch {
        fail("dump failed: \(error)")
    }

case "check":
    // Builds a GPU pipeline for every translated kernel.
    do {
        let dll = resolveDLL(args)
        let url = try LSFGKernels.defaultLibraryURL(forDLL: dll)
        let start = Date()
        let kernels = try LSFGKernels(libraryURL: url)
        let shaders = try LSFGShaderLibrary(dll: dll)
        var mismatched = 0
        for e in shaders.entries {
            guard let p = kernels.pipelines[e.resourceID] else { print("missing kernel \(e.resourceID)"); mismatched += 1; continue }
            if let g = e.shader.threadGroupSize, Int(g.x * g.y * g.z) > p.maxTotalThreadsPerThreadgroup {
                print("kernel \(e.resourceID): group \(g.x)x\(g.y)x\(g.z) exceeds max \(p.maxTotalThreadsPerThreadgroup)")
                mismatched += 1
            }
        }
        print("\(kernels.pipelines.count)/\(shaders.entries.count) pipelines built on \(kernels.device.name) in "
              + String(format: "%.2fs", Date().timeIntervalSince(start)) + ", \(mismatched) problems")
        if mismatched > 0 { exit(1) }
    } catch {
        fail("check failed: \(error). Run scripts/translate-shaders.sh first.")
    }

default:
    print(usage)
}
