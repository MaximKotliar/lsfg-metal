# LSFG 3.1 on Metal: real game footage

Tested 2026-10-31 with `lsfg-metal eval` on The Last of Us Part II Remastered (PC, 1080p60). The footage is the first ~33 s of a YouTube gameplay recording (H.264, so with some compression noise), used only locally and not stored in the repo.

## Method

Every other frame of the 60 fps recording is the "real" 30 fps stream. LSFG generates the frame between each pair of real frames, and that frame is compared with the frame the game actually rendered there. The first two pairs are left out while LSFG's 3-frame history fills. Frame pairs that span a camera cut are skipped.

## Results (M4 Max, fp16, flow scale 1.0)

| Window | Frames | LSFG quality PSNR / SSIM | LSFG performance PSNR / SSIM | 50/50 blend PSNR / SSIM | Repeat PSNR | LSFG beats blend |
| --- | --- | --- | --- | --- | --- | --- |
| 2–4 s, walking, horse | 59 | 35.3 / 0.958 | 35.0 / 0.954 | 27.6 / 0.751 | 25.5 | 56/59 |
| 10–12 s, walking, camera turn | 59 | 34.6 / 0.949 | 34.2 / 0.948 | 25.6 / 0.754 | 23.6 | 59/59 |
| 20–22 s, climbing | 59 | 32.7 / 0.964 | 31.5 / 0.958 | 23.4 / 0.789 | 20.4 | 59/59 |
| 28–30 s, fast camera turn | 58 | 36.5 / 0.974 | 36.5 / 0.973 | 28.0 / 0.896 | 26.5 | 56/58 |

PSNR and SSIM are medians. Overall, LSFG beats the blend on 230 of 235 frames, by about 8–9 dB of PSNR and about 0.2 of SSIM. Performance mode is within 0–1.2 dB of quality mode, so on this content it's the better trade.

## What the bad frames look like

The few frames where the blend scores higher aren't broken. LSFG's frame is clean and coherent, but the camera was accelerating, so the real in-between frame wasn't halfway between its neighbours. A correct-looking frame a few pixels off is penalized by PSNR more than a blurry blend is. Interpolation from two frames can't know about acceleration; this is expected.

Visible artifacts are the usual ones for image-only interpolation: small warps at the edges of moving objects where background gets uncovered.

## Inputs LSFG uses

LSFG works from the two color frames only. It has no depth or motion vectors from the game. That's why it works on any game, and why it can't fully resolve uncovered areas the way engine-integrated methods can (DLSS FG, FSR 3, MetalFX frame interpolation).

It has a built-in UI heuristic: `beta4` thresholds a 6-level mask pyramid with `uiThreshold` (0.5) to limit warping in static regions. There's no separate UI-layer input. Generating the frame below the HUD needs the game's frame split into scene and UI before LSFG sees it. That belongs to part 2 (interposition).
