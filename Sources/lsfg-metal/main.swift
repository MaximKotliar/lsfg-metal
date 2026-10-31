import Foundation
import LSFGCore

let usage = """
usage: lsfg-metal <command> [options]

commands:
  locate              find Lossless Scaling (Steam app \(LosslessInstall.steamAppID)) in CrossOver bottles
  inspect [--dll P]   list the LSFG compute shaders in Lossless.dll and their bindings
                      add --verbose for per-binding detail
  dump --out DIR      write the shaders as .dxbc / .spv files (keep DIR outside the repo)
  check               build a Metal pipeline for every translated kernel
  generate PREV NEXT -o OUT.png [--multiplier N] [--flow-scale F] [--fp32] [--performance] [--runs N]
                      write the frame(s) between two images using LSFG 3.1 on Metal
  eval VIDEO|DIR [--start S] [--count N] [--max-width W] [--flow-scale F] [--performance] [--samples DIR]
                      score generated frames against a real recording (every other frame is held out)
  bench PREV NEXT [--frames N] [--sizes WxH,...]
                      sustained benchmark across sizes, modes, flow scales and multipliers

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
        print("\(lib.entries.count) DXBC + \(lib.spirv.count) SPIR-V shaders in \(dll.lastPathComponent)\n")
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
        for (id, code) in lib.spirv { try code.write(to: out.appending(path: "\(id).spv")) }
        print("wrote \(lib.entries.count) DXBC and \(lib.spirv.count) SPIR-V shaders to \(out.path)")
    } catch {
        fail("dump failed: \(error)")
    }

case "check":
    // Builds a GPU pipeline for every translated kernel.
    do {
        let start = Date()
        let kernels = try LSFGKernels(cacheDirectory: try LSFGKernels.cacheDirectory(forDLL: resolveDLL(args)))
        print("\(kernels.kernels.count) pipelines built on \(kernels.device.name) in "
              + String(format: "%.2fs", Date().timeIntervalSince(start)))
    } catch {
        fail("check failed: \(error). Run scripts/translate-shaders.sh first.")
    }

case "generate":
    // lsfg-metal generate PREV NEXT -o OUT [--multiplier N] [--flow-scale F] [--fp32] [--performance] [--runs N]
    let positional = args.dropFirst().enumerated().filter { i, a in
        !a.hasPrefix("-") && (i == 0 || !["-o", "--multiplier", "--flow-scale", "--dll", "--runs"].contains(args[i]))
    }.map(\.1)
    guard positional.count == 2, let o = args.firstIndex(of: "-o"), o + 1 < args.count else {
        fail("usage: lsfg-metal generate PREV NEXT -o OUT.png [--multiplier N] [--flow-scale F] [--fp32] [--performance] [--runs N]")
    }
    func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    var settings = LSFGSettings()
    settings.multiplier = value("--multiplier").flatMap(Int.init) ?? 2
    settings.flowScale = value("--flow-scale").flatMap(Float.init) ?? 1.0
    settings.fp16 = !args.contains("--fp32")
    settings.performance = args.contains("--performance")
    let runs = max(1, value("--runs").flatMap(Int.init) ?? 1)
    guard (2...8).contains(settings.multiplier), (0.25...1.0).contains(settings.flowScale) else {
        fail("--multiplier must be 2...8 and --flow-scale 0.25...1.0")
    }
    do {
        let prev = try FrameIO.load(URL(fileURLWithPath: positional[0]))
        let next = try FrameIO.load(URL(fileURLWithPath: positional[1]))
        guard prev.width == next.width, prev.height == next.height else { fail("frames must be the same size") }

        let loadStart = Date()
        let kernels = try LSFGKernels(cacheDirectory: try LSFGKernels.cacheDirectory(forDLL: resolveDLL(args)),
                                      ids: LSFG31Shaders.allIDs(fp16: settings.fp16, performance: settings.performance))
        let loadTime = Date().timeIntervalSince(loadStart)
        var lsfg = try LSFG31(width: prev.width, height: prev.height, settings: settings, kernels: kernels)
        guard let queue = kernels.device.makeCommandQueue() else { fail("no command queue") }

        // Fill all three history slots: prev, prev, then next generates prev→next.
        func submit(_ frame: FrameIO.Image, generate: Bool) throws -> Double {
            FrameIO.upload(frame, to: lsfg.nextInput)
            guard let cb = queue.makeCommandBuffer() else { fail("no command buffer") }
            try lsfg.encode(into: cb, generate: generate)
            cb.commit()
            cb.waitUntilCompleted()
            if let error = cb.error { throw error }
            return (cb.gpuEndTime - cb.gpuStartTime) * 1000
        }
        _ = try submit(prev, generate: false)
        _ = try submit(prev, generate: false)
        var times: [Double] = []
        for run in 0..<runs {
            // Repeat the measured frame with the same history for timing runs.
            if run > 0 { _ = try submit(prev, generate: false); _ = try submit(prev, generate: false) }
            times.append(try submit(next, generate: true))
        }

        let out = URL(fileURLWithPath: args[o + 1])
        for (i, tex) in lsfg.outputs.enumerated() {
            let url = lsfg.outputs.count == 1 ? out
                : out.deletingPathExtension().appendingPathExtension("\(i + 1).png")
            try FrameIO.save(FrameIO.download(tex), to: url)
            print("wrote \(url.path)")
        }
        let sorted = times.sorted()
        print(String(format: "%dx%d, %d generated, flow %.2f, %@, %@: pipelines %.2fs, GPU %.2f ms (median of %d)",
                     prev.width, prev.height, settings.generationCount, settings.flowScale,
                     settings.fp16 ? "fp16" : "fp32", settings.performance ? "performance" : "quality", loadTime, sorted[sorted.count / 2], runs))
    } catch {
        fail("generate failed: \(error)")
    }

case "bench":
    // lsfg-metal bench PREV NEXT [--frames N] [--sizes 1280x720,1920x1080,...]
    guard args.count >= 3 else { fail("usage: lsfg-metal bench PREV NEXT [--frames N] [--sizes WxH,...]") }
    func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    let frames = value("--frames").flatMap(Int.init) ?? 300
    let sizes = (value("--sizes") ?? "1280x720,1920x1080,2560x1440,3840x2160").split(separator: ",").map {
        let p = $0.split(separator: "x").compactMap { Int($0) }; return (p[0], p[1])
    }
    do {
        let a = try FrameIO.load(URL(fileURLWithPath: args[1])), b = try FrameIO.load(URL(fileURLWithPath: args[2]))
        let dir = try LSFGKernels.cacheDirectory(forDLL: resolveDLL(args))
        let kernels = try LSFGKernels(cacheDirectory: dir, ids: LSFG31Shaders.allIDs(fp16: true, performance: false)
                                          .union(LSFG31Shaders.allIDs(fp16: true, performance: true)))
        print("device: \(kernels.device.name), \(frames) frames per row, 3 in flight, fp16\n")
        print("size       mode  flow  mult  GPU med  GPU p95  CPU enc  max fps  mem MB  dispatches")
        for (w, h) in sizes {
            let pa = FrameIO.resized(a, width: w, height: h), pb = FrameIO.resized(b, width: w, height: h)
            for perf in [false, true] { for flow in [Float(1.0), 0.5] { for mult in [2, 3, 4] {
                if mult > 2 && flow != 0.5 { continue }
                var s = LSFGSettings()
                s.performance = perf; s.flowScale = flow; s.multiplier = mult
                let r = try runBench(prev: pa, next: pb, settings: s, kernels: kernels, frames: frames)
                print(String(format: "%-10@ %-5@ %4.2f  %4d  %6.2f   %6.2f   %6.3f   %7.0f  %6.0f  %d",
                             "\(w)x\(h)" as NSString, (perf ? "perf" : "qual") as NSString, flow, mult,
                             r.gpuMedian, r.gpuP95, r.cpuEncode, r.throughputFPS, r.memoryMB, r.dispatches))
            } } }
        }
    } catch {
        fail("bench failed: \(error)")
    }

case "eval":
    // lsfg-metal eval VIDEO|DIR [--start S] [--count N] [--max-width W] [--flow-scale F] [--performance] [--samples DIR]
    guard args.count >= 2 else { fail("usage: lsfg-metal eval VIDEO|FRAME_DIR [--start S] [--count N] [--max-width W] [--flow-scale F] [--performance] [--samples DIR]") }
    func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    var opts = EvalOptions()
    opts.start = value("--start").flatMap(Double.init) ?? 0
    opts.count = value("--count").flatMap(Int.init) ?? 121
    opts.maxWidth = value("--max-width").flatMap(Int.init) ?? 1920
    opts.settings.flowScale = value("--flow-scale").flatMap(Float.init) ?? 1.0
    opts.settings.performance = args.contains("--performance")
    opts.samples = value("--samples").map { URL(fileURLWithPath: $0) }
    do {
        let raw = try await loadFrames(from: URL(fileURLWithPath: args[1]), options: opts)
        let (frames, dropped) = dropDuplicates(raw)
        guard frames.count >= 7 else { fail("need at least 7 distinct frames, got \(frames.count)") }
        let span = (raw.last!.time - raw.first!.time)
        print(String(format: "%d frames decoded (%.1f fps source), %d duplicates dropped, %dx%d",
                     raw.count, Double(raw.count - 1) / max(span, 0.001), dropped, frames[0].image.width, frames[0].image.height))
        let kernels = try LSFGKernels(cacheDirectory: try LSFGKernels.cacheDirectory(forDLL: resolveDLL(args)),
                                      ids: LSFG31Shaders.allIDs(fp16: true, performance: opts.settings.performance))
        let scores = try evaluate(frames: frames, options: opts, kernels: kernels)
        report(scores, label: String(format: "%@, flow %.2f", opts.settings.performance ? "performance" : "quality",
                                     opts.settings.flowScale))
    } catch {
        fail("eval failed: \(error)")
    }

default:
    print(usage)
}
