# LSFG 3.1 on Metal: performance and Mac feasibility

Measured 2026-10-31 on a MacBook Pro, Apple M4 Max (40-core GPU, 48 GB), macOS 27.2, on AC power.
Shaders: the fp16 variants from Lossless.dll, auto-translated to Metal (no hand tuning yet).

## How it was measured

`lsfg-metal bench PREV NEXT` runs 300 frames back to back after 30 warm-up frames, with 3 frames in flight. That's how a presentation hook would drive it, so the GPU stays clocked up. Each real frame is:

1. A GPU copy of the new real frame into the LSFG input (what a hook would do with the game's drawable).
2. The analysis passes for that frame (mipmaps, alpha, beta: 34 dispatches).
3. One generation pass per in-between frame (gamma, delta, generate: 66 dispatches each).

"GPU" is `gpuEndTime − gpuStartTime` of that command buffer, so it's the full cost LSFG adds per **real** frame, including all generated frames. "Max fps" is how many real frames per second LSFG alone could sustain.

Quality numbers come from a synthetic pair (photo panned 16 px plus a disc moving 120 px), compared with the true midpoint:

| | PSNR |
| --- | --- |
| Quality mode, flow 1.0 | 32.4 dB |
| Quality mode, flow 0.5 | 33.0 dB |
| Performance mode, flow 1.0 | 32.9 dB |
| 50/50 blend | 21.8 dB |
| Repeat previous frame | 19.6 dB |

On this simple test the two modes come out about equal. Real game content (fine detail, UI, particles) is where quality mode should pull ahead.

## Results (M4 Max)

GPU time per real frame in ms (median / p95), for 2× (one generated frame):

| Output | Quality, flow 1.0 | Quality, flow 0.5 | Performance, flow 1.0 | Performance, flow 0.5 |
| --- | --- | --- | --- | --- |
| 1280×720 | 1.03 / 1.40 | 0.84 / 1.21 | 0.49 / 0.84 | 0.42 / 0.74 |
| 1920×1080 | 1.55 / 1.92 | 0.99 / 1.36 | 0.74 / 1.09 | 0.52 / 0.87 |
| 2560×1440 | 2.20 / 2.56 | 1.23 / 1.60 | 1.04 / 1.43 | 0.68 / 1.06 |
| 3840×2160 | 4.53 / 4.62 | 1.91 / 2.31 | 1.96 / 2.35 | 1.11 / 1.46 |

Higher multipliers at flow 0.5 (each extra generated frame adds a gamma/delta/generate pass):

| Output | Quality 3× | Quality 4× | Performance 3× | Performance 4× |
| --- | --- | --- | --- | --- |
| 1920×1080 | 1.67 | 2.32 | 0.87 | 1.20 |
| 2560×1440 | 2.09 | 2.92 | 1.11 | 1.56 |
| 3840×2160 | 3.21 | 4.75 | 1.80 | 2.49 |

Other costs:

- **CPU:** 0.08–0.31 ms per real frame to encode 100–232 dispatches. That matters because games under CrossOver are often CPU-bound (Rosetta plus Wine), and LSFG barely touches the CPU.
- **Memory:** 16–272 MB of textures (4K quality at flow 1.0 is the largest). Trivial on unified memory.
- **Startup:** building the 26 pipelines one mode needs takes about 0.05 s with a warm Metal shader cache. The very first build of all 300 kernels took 18–28 s, so a shipped tool should precompile into an `MTLBinaryArchive`.

## What this means for playing on a Mac

GPU share LSFG takes at 2× (60 → 120 fps on a ProMotion display, 16.7 ms per real frame):

| Setting | GPU time | Share of a 16.7 ms frame |
| --- | --- | --- |
| 1440p, performance, flow 0.5 | 0.68 ms | 4% |
| 1440p, quality, flow 1.0 | 2.20 ms | 13% |
| 4K, performance, flow 0.5 | 1.11 ms | 7% |
| 4K, quality, flow 1.0 | 4.53 ms | 27% |

At 30 → 60 fps (33 ms per real frame) these shares halve.

**CPU-bound games** (the TLOU2-on-Deck situation, and common under Rosetta): the GPU has spare time, so LSFG is close to free and doubles the shown frame rate. This is the case frame generation is best at.

**GPU-bound games:** LSFG time comes straight out of the game's frame. For example, a game at exactly 60 fps at 1440p with quality/flow 1.0 drops to about 1000 / (16.7 + 2.2) ≈ 53 real fps, shown as about 106 fps. Performance mode at flow 0.5 costs only about 2 real fps.

**Other Macs (estimates, not measured):** the M4 Max has a 40-core GPU and 546 GB/s of memory bandwidth. Expect about 4× these times on a 10-core M4 and about 6–8× on an 8-core M1. On an M1 MacBook Air, 1080p performance mode at flow 0.5 should cost roughly 3–4 ms, which is fine for 30 → 60 or 45 → 90. Quality mode at 1440p and above will be heavy on base chips. These need checking on real hardware.

**Latency:** like every interpolation method, LSFG has to wait for the next real frame, which adds about one real-frame interval (16.7 ms at 60 real fps) plus the GPU time above. That's the same as LSFG on Windows or a Steam Deck. A 40+ fps real-frame base keeps it acceptable.

## Verdict

The network itself is feasible on Apple Silicon: on an M4 Max it costs 0.4–4.5 ms per real frame at 2×, uses almost no CPU, and needs very little memory, even before any hand tuning. The open risks are elsewhere:

1. **Getting frames in and out of a CrossOver game (part 2).** `DYLD_INSERT_LIBRARIES` is ignored by CrossOver's hardened `wineloader`, so another injection route is needed.
2. **Frame pacing on macOS:** presenting the generated frame at the midpoint (`presentDrawable(_:atTime:)`) with stable timing.
3. **Base and Pro chips:** measure there before promising quality mode at high resolutions.
4. **Real game frames:** check quality, especially around HUD and UI elements.

Not measured: power draw (needs `sudo powermetrics`), thermals in long sessions, and contention with a real game running at the same time.
