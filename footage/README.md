# footage/ — video cleanup toolkit (`footage-kit`)

A pipeline for cleaning up camera/tape footage on this machine's
resources: **VapourSynth** (crop → deinterlace → temporal denoise) →
**video2x** (RealESRGAN upscale, RIFE interpolation — both on Vulkan,
so they run on the AMD GPUs here) → **FFmpeg** (x265/SVT-AV1/x264 or
VAAPI encode, audio stream-copied, color tags restamped sanely).

Everything is pinned nixpkgs — no ad-hoc installs. Two nixpkgs packages
get a one-line source fix at this pin (gcc-16/fmt-12 breakage; see the
comment in `kit.nix`).

## Quick start

```sh
just build-kit                                # or: nix build .#footage-kit
nix run .#footage-kit -- --help               # footage-clean --help
just probe ~/Downloads/n265.mp4               # what is this file?
just footage --test 12 ~/Downloads/n265.mp4   # short test render FIRST
just footage --denoise standard --deband ~/Downloads/n265.mp4
# analog PCTV capture (crop bars + head-switch band, idet picks the field order):
just footage --deint qtgmc --denoise light --crop 700x556+10+2 captures/<file>.mpg
```

Built binaries: `result/bin/footage-clean`, `result/bin/footage-probe`.
The pipeline script lives at `share/footage/clean.vsh` (editable copy in
this repo; rebuild to apply changes).

## How the standard workflow maps onto this kit

The usual advice is *FFmpeg + VapourSynth + QTGMC → BM3D/KNLMeans →
Real-ESRGAN via vs-mlrt → FFmpeg encode*. On this machine, with this
pinned nixpkgs, it lands like this:

| step              | classic advice                | what this kit actually runs                                |
| ----------------- | ----------------------------- | ---------------------------------------------------------- |
| deinterlace       | QTGMC (Avisynth/havsfunc)     | QTGMC-style chain built from the packaged parts: znedi3/eedi3 field-interpolation → MVTools FlowInter → MDegrain (`--deint qtgmc`). Real QTGMC.py needs fmtconv + havsfunc, which nixpkgs does not carry — the substitution is honest and close (`slower` preset minus the source-match passes). `bwdif` via plain FFmpeg is the fast fallback. |
| denoise           | BM3D / KNLMeansCL / SMDegrain | MDegrain (MVTools) temporal denoise, 4 strengths (`--denoise light..stronger`) + chroma BoxBlur. BM3D/KNLMeans VS plugins aren't packaged; motion-compensated averaging is the right tool for exactly the noise these files have (per-frame sensor noise + compression banding). |
| tape artifacts    | FixChromaBleeding etc.        | the analog path today is the PCTV MPEG-2 capture: crop (pillar bars + head-switching band, `--crop 700x556+10+2`), `--deint qtgmc`, `--denoise light` and `--grade` handle combing, tape noise and faded colour; verified on `captures/pctv-cap-20261101-210236.mpg`. Composite-level fixes (color bleed, WRNAGS) would need avs-xf/fmtconv vendored first; noted under "extension points". |
| upscale           | vs-mlrt + ONNX models         | **video2x → realesrgan-ncnn-vulkan** (Vulkan/Mesa, works on the R9700 and the RX 580). vs-mlrt's ONNX runtime has no AMD-relevant EP on Linux; ncnn-vulkan is the same net, and video2x also carries RIFE. |
| interpolation     | RIFE                          | **video2x rife-ncnn-vulkan** (`--interp`). |
| encode            | x265                          | libx265 default; `--codec av1|x264|gpu-h265|gpu-h264`. Note AMF encoders do **not** work on Linux (they need the Windows AMF runtime); VAAPI is the GPU path (tested on renderD128). |

## What's in `~/Downloads` right now (probed 2026-11-01)

`a265.mp4` / `y265.mp4` / `n265.mp4` — 2560×1080 HEVC travel clips
(3motion.tv watermarked), 25/50 fps, mp3 audio, all **progressive**
(idet: zero TFF/BFF fields). `y265`/`n265` are tagged
`color_matrix=bt2020c` (constant luminance) — no consumer device writes
that; it's a bad tag, and it breaks any plain `ffmpeg scale/format`
conversion. footage-clean decodes them fine, applies bt709 tags on the
output, and denoise is aimed at their real defects (sky banding +
shadow noise). `Apollonian.mp4` is a clean 1080p sample — no cleanup
needed.

## GPU etiquette on zen3-nixos

The R9700 is a **lease** (`gpu-mode llm|sd|game`; Strata normally holds
it). video2x enumerates Vulkan devices like this (from the build box,
2026-11-01):

```
0. AMD Radeon RX 580 Series   (POLARIS10)   <- default, free for GPU stages
1. AMD Radeon AI PRO R9700    (GFX1201)     <- Strata's card, use --gpu 1
2. llvmpipe (software)
```

Measured on the RX 580 (2026-11-01): RealESRGAN x2 2560×1080→5120×2160
≈ **0.7 fps** (a 19-minute clip ≈ 22 h — schedule accordingly or move to
the R9700 with `--gpu 1`, whose fp16 support is complete where Polaris'
is not); RIFE 2× at 2560×1080 ≈ **11 fps**. VapourSynth MDegrain
(standard) ≈ 40 fps and x265 medium ≈ 55 fps at that size on the 5950X.
VAAPI HEVC encode (`--codec gpu-h265`) runs on renderD128 (RX 580) and
was verified end-to-end; AMF does not work on Linux at all (missing
Windows-only runtime). `VapourSynth + x265` never touch VRAM.

## Enhancement experiments (2026-11-01, on the PCTV capture)

Two 5 s samples of the cleaned 700×556/50p PCTV render (drive segment =
roadside pylons/foliage, stage-show segment = fine set detail), compared
as 1:1 crops at equal output size. CPU-side first:

* `--grade` (sat 1.18 / contrast 1.04) — **the cheap win** on faded
  analog colour; keep on for tape.
* `--sharpen 0.4` — safe, mild crispness; ≥0.6 starts ringing.
* `--deband` — marginal after MDegrain (temporal averaging already
  smooths gradients); keep opt-in for nastier sources.

GPU upscalers (RX 580, 5 s/250-frame clips, all at x2 of the sample):

| variant | result | time | verdict |
| --- | --- | --- | --- |
| lanczos x2 | soft, no artefacts | <5 s | the bar to beat |
| `--model realesr-animevideov3` (default) | natural detail, no artefacts seen | ~45 s | **best all-rounder, the kit default** |
| `--processor realcugan --model models-pro` | sharpest, nicest texture on foliage/set | ~50 s | runner-up; occasionally over-crisp on edges — spot-check faces |
| realesrgan-plus x4 → lanczos ½ | ~indistinguishable from animevideov3 at x2 | ~23 min | **not worth ~30× the cost**; reserve for hero stills/clips |

libplacebo is **not** in this nixpkgs' video2x build (`Filter
'libplacebo' not found`) — no RAISR/Animeweb upscalers via this route.

Extrapolated to the full 29-min capture at x2: ≈ 4–5 h on the RX 580 —
run it on the R9700 (`--gpu 1` after `gpu-mode game`; expect several
×  faster on RDNA4) as a dedicated session, not beside Strata (475 MB
VRAM free with the LLM resident).

## Notes

* `--test N` samples with `-c copy`, which snaps to keyframes — expect
  the sample to run to the next GOP boundary, not to exactly N seconds.
* Sources tagged `matrix=bt2020c` get an automatic no-filter
  VapourSynth "tag normalisation" pass before any stage that converts
  colour (video2x / VAAPI / the bt709 restamp); the message says so.
* Stage 1's intermediate is `libx264 crf 12` (visually lossless for
  this pipeline's purposes).

## Files

| file                | role                                                          |
| ------------------- | ------------------------------------------------------------- |
| `kit.nix`           | the package: patched znedi3 + video2x, plugin set, script substitution |
| `clean.vsh`         | VapourSynth pipeline (env-var driven: `FC_SRC`/`FC_DEINT`/`FC_FIELD`/`FC_DENOISE`/`FC_CHROMA_BLUR`/`FC_CROP`) |
| `footage-clean.sh`  | CLI orchestrator (probe → stages → encode)                    |
| `footage-probe.sh`  | standalone "what is this file / what should I run" report     |

## Extension points (deliberately not in v1)

* **Real QTGMC + DeSpot/Deen chains**: vendor fmtconv (release tarballs,
  plugin-dir drop-in) and havsfunc (pure Python) as a source-level
  plugin set — ~1 package each. Worth doing the first time actual
  interlaced tape captures need a run.
* **BM3D**: `icbm3d` is packaged standalone (image tool); the
  VapourSynth-BM3D plugin is a meson build against fftw — also easy to
  vendor if wanted.
* **KNLMeansCL**: needs an OpenCL ICD usable by VapourSynth; on this
  box that's ROCm/POCL territory — `nnedi3cl` at least loads, so an ICD
  exists; not yet exercised.
* **RF-level tape capture** (vhs-decode/ld-decode) needs capture
  hardware and is out of scope here.
