# lsfg-metal

Lossless Scaling's frame generation (LSFG 3.1) on Metal, for developers: a Swift library and a C API that run LSFG's
passes as native Metal compute kernels on Apple silicon, plus a command-line tool to translate, check, benchmark and
evaluate them.

Only for people who own [Lossless Scaling on Steam](https://store.steampowered.com/app/993090/). LSFG's shaders and
weights are read at run time from the user's own `Lossless.dll`. This repository never contains the DLL, its shaders
or anything derived from them.

For the app that puts this into games running under CrossOver, see
[Lightscale](https://github.com/MaximKotliar/lightscale). Its upscaling companion is
[nss-metal](https://github.com/MaximKotliar/nss-metal), a Metal port of Arm's
[Neural Super Sampling](https://huggingface.co/Arm/neural-super-sampling).

## What's here

| Part | What it is |
|---|---|
| `LSFGCore` (Swift) | Finds `Lossless.dll`, reads its DXBC/SPIR-V shaders, translates them to Metal (SPIRV-Cross), builds the pipelines, and runs the LSFG 3.1 pass graph (quality and performance modes, 2×–4×) on `MTLTexture`s. Also loads pre-baked kernels whose weights are filled in from the DLL. |
| `LSFGBridge` (C API, dynamic library) | `lsfg_bridge_create` / `_input` / `_encode` / `_output` / `_destroy`: the same engine for hosts that aren't Swift. Builds for x86_64 too (`swift build --arch x86_64 --product LSFGBridge`), for Rosetta processes such as Wine. |
| `lsfg-metal` (CLI) | `locate`, `inspect`, `dump`, `check`, `generate`, `eval`, `profile`, `bench`, `bake`. |

Use it from SwiftPM:

```swift
.package(url: "https://github.com/MaximKotliar/lsfg-metal", branch: "main")
// target dependency: .product(name: "LSFGCore", package: "lsfg-metal")
```

## Performance

Sustained GPU cost per real frame at 2× on an M4 Max: 0.4–2.0 ms at 1080p–1440p, 1.1–4.5 ms at 4K (before the
scheduling optimizations, which took 10–25% off). CPU cost is about 0.1 ms. Performance mode is about twice as fast
as quality mode. Full tables: [docs/performance.md](docs/performance.md). On real game footage (TLOU2) the generated
frame beats a 50/50 blend on 230 of 235 frames by about 8–9 dB: [docs/real-footage.md](docs/real-footage.md).

Synthetic pair (photo panned 16 px plus a disc moving 120 px):

| | PSNR vs true midpoint |
| --- | --- |
| LSFG 3.1 on Metal | 32.4 dB (flow 1.0), 33.0 dB (flow 0.5) |
| 50/50 blend | 21.8 dB |
| Repeat previous frame | 19.6 dB |

## Pre-baked kernels, weights from the DLL

`lsfg-metal bake --out DIR` compiles every LSFG 3.1 shader once with all floating-point constants (the weights) lifted out into zeroed Metal function constants. The resulting `lsfg-skeleton.metallib` plus `manifest.json` (a structure hash per kernel) contain no weights. At run time the engine reads the constants from the user's own `Lossless.dll`, checks each shader's structure hash, and specializes the pipelines with `MTLFunctionConstantValues`:

- **Same speed** as locally translated kernels (within ±3%). Rounding differs by at most 1/255.
- **Fast startup:** about 0.3 s cold, about 0.07 s once Metal has cached the pipelines.
- **No developer tools for end users:** no `spirv-cross` or Xcode. Only if a Lossless Scaling update changes a shader's structure does a one-time local build happen.

The skeleton contains no weights, but it's still a translation of Lossless Scaling's shader code, so it's kept out of git. Distributing it is a separate decision.

## Setup (command line)

```bash
brew install spirv-cross spirv-tools
```

LSFG 3.1 only needs the SPIR-V shaders. To also translate the DXBC ones (upscalers, older LSFG), build [dxbc-spirv](https://github.com/doitsujin/dxbc-spirv) with `-Denable_tools=true` and set `DXBC_COMPILER` to its `dxbc_compiler`.

Install Lossless Scaling with Steam inside a CrossOver bottle, then:

```bash
swift run lsfg-metal locate                       # find Lossless.dll
scripts/translate-shaders.sh                      # → ~/Library/Caches/lsfg-metal/<dll hash>/
swift run lsfg-metal check                        # build all Metal pipelines
swift run -c release lsfg-metal generate prev.png next.png -o mid.png
```

Translated output is cached in `~/Library/Caches/lsfg-metal/<dll hash>/`.

## Commands

- `locate`: finds Lossless Scaling installs in every bottle folder CrossOver uses: its default `~/Library/Application Support/CrossOver/Bottles`, a custom folder set in CrossOver's settings (`BottlePath`) or by `CX_BOTTLE_PATH` (as CXPatcher builds do, `~/CXPBottles`), plus any `LSFG_BOTTLES` folders.
- `inspect [--verbose]`: lists the shaders with thread-group size, instruction count and named bindings.
- `dump --out DIR`: writes the shaders as `.dxbc` files. Keep `DIR` outside the repo.
- `check`: builds a Metal pipeline for every translated kernel.
- `generate PREV NEXT -o OUT.png [--multiplier N] [--flow-scale F] [--fp32] [--performance] [--runs N]`: writes the generated frame(s) between two images. With `--multiplier 3` or more it writes `OUT.1.png`, `OUT.2.png`, and so on.
- `eval VIDEO|DIR [--start S] [--count N] [--max-width W] [--flow-scale F] [--performance] [--samples DIR]`: scores LSFG on real footage. It keeps every other frame of a 60 fps recording as the "real" 30 fps stream, generates the frame in between, and compares it with the frame the game actually rendered (PSNR and SSIM, against a blend and a repeat). `--samples` writes truth | generated | blend images.
- `profile PREV NEXT [--size WxH] [--performance] [--flow-scale F]`: GPU time per pass.
- `bench PREV NEXT [--frames N] [--sizes WxH,...]`: sustained benchmark across sizes, modes, flow scales and multipliers.

## Credits

The LSFG 3.1 pass graph, shader ID table and constant-buffer layout in `Sources/LSFGCore/LSFG31.swift` follow [lsfg-vk](https://github.com/PancakeTAS/lsfg-vk) at its MIT-licensed revisions (MIT License, Copyright (c) 2025 lsfg-vk). Later lsfg-vk releases use CC BY-NC-ND 4.0, and nothing here comes from them.

Shader translation uses [dxbc-spirv](https://github.com/doitsujin/dxbc-spirv) (MIT) and [SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross) (Apache 2.0) as external tools.

## License

MIT (see [LICENSE](LICENSE)). Lossless Scaling, its DLL and its shaders are not covered: they're the user's own
licensed copy, read at run time.
