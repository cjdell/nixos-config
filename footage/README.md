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

## How to use it

Two commands. `footage-probe` only reports; `footage-clean` does the
work. Both run with zero setup — every tool is a baked-in store path,
so neither needs PATH, Nix shell or root.

```sh
just probe FILE          # or: result/bin/footage-probe FILE
just footage [flags] FILE [OUT]
```

`just` rebuilds the kit on every invocation (seconds when unchanged);
`result/bin/...` uses the last `nix build .#footage-kit` output. Output
defaults to `<input>-cleaned.mp4`. `footage-clean --help` lists every
flag with its default.

### The workflow, every time

1. **`footage-probe FILE`** — reads resolution, bitrate per pixel,
   field order (container tag *and* ffmpeg `idet` counts, and says
   which one it trusts) and colour tags, then prints suggested
   commands. The probe answer is the flag list for step 2.
2. **`footage-clean --test 12 ... FILE /tmp/t.mp4`** — renders ~12
   seconds (keyframe-snapped) with the real flags. Always. A wrong
   `--deint`/`--crop`/field-order guess costs hours on a 29-minute
   capture, 8 seconds on a test.
3. **Full render.** Stages run in the canonical order — crop →
   deinterlace → denoise → (GPU upscale → RIFE) → encode — stages 3-5
   skipped unless asked for. Intermediates are visually-lossless
   (crf 12); the final encode is what you keep. Audio is stream-copied.
   Progress prints per stage; temp dir auto-deletes (`--keep-temp`
   keeps it).
4. **Check the result**: ffprobe the output (size, fps, tags) and pull
   one frame from near the end — banding, cropping or field-order
   mistakes show up there.

### Choosing the flags

* **Interlaced (tape, PCTV, DVD rips)?** `--deint auto` is right 95 %
  of the time: it believes `idet` over the container tag (the PCTV
  driver writes a bogus `bb`; idet found TFF=250/BFF=0 and the kit
  overrode it correctly). Override with `--deint qtgmc|znedi3|eedi3` +
  `--field tff|bff` when you know better. Interlaced sources come out
  as full-rate 50p, never 25p.
* **Overscan / head-switching band / pillar bars?** `--crop WxH+X+Y`,
  found with `ffmpeg -vf cropdetect`. Applied *before* deinterlacing.
* **Noise level?** `--denoise light` for tape (MDegrain keeps detail),
  `standard` default for digital, `strong/stronger` for bad sensor
  noise, `none` for clean sources going straight to upscale.
* **Washed-out analog colour?** `--grade` (saturation 1.18 / contrast
  1.04) — the single biggest win on VHS-era captures. `--deband` for
  banded skies; `--sharpen 0.4` if the source is soft and you are not
  upscaling with a net anyway.
* **Upscale?** `--upscale 2|3|4` on the GPU. **Default model
  `realesr-animevideov3` — chosen deliberately** (see the experiments
  section: best natural detail per second on video content;
  `--processor realcugan --model models-pro` when you want maximum
  sharpness and will check faces). Stay at ×2 and let the player
  finish to ×4: realesrgan-plus ×4 costs ~30× for no visible gain.
* **Frame rate?** `--interp` doubles it with RIFE (25p→50p, 50p→100p).
* **GPU choice?** GPU stages default to Vulkan device 0 = the RX 580,
  so renders run *while Strata holds the R9700*. `--gpu 1` after
  `gpu-mode game` for the fast card (see *GPU etiquette*).
* **Delivery vs archive?** `--crf` (20 default; 16 for master-grade,
  24 for space) and `--codec x265|x264|av1|gpu-*`. x265 medium on the
  5950X ≈ 2.2× realtime; `gpu-h265` offloads VCN to the RX 580.
* **Colour tags:** output is stamped bt709; `--source-color` keeps the
  source's (broken) tags instead. Mislabelled `bt2020c` sources get an
  automatic normalising pass — that's a fix, not a bug.

### Recipes that are known good

```sh
# PCTV/VHS MPEG capture -> clean 50p HEVC (the 2026-11-01 render):
just footage --deint qtgmc --denoise light --grade --crop 700x556+10+2 captures/x.mpg

# ...same, upscaled x2 for the collection, on the RX 580 (~4.5 h per 29 min):
just footage --deint qtgmc --denoise light --grade --crop 700x556+10+2 \
  --upscale 2 captures/x.mpg        # add --gpu 1 when the R9700 lease is free

# digital travel clip: denoise banding, sharper, small file:
just footage --denoise standard --deband --crf 22 n265.mp4

# SD DVD rip to a crisp 2x with the sharper net:
just footage --deint auto --denoise light --upscale 2 --processor realcugan vob.mkv
```

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

**Decision (2026-11-01): `realesr-animevideov3` ×2 is the kit's default
upscale recipe** — natural detail, no artefacts in stills or motion,
and ~the same cost as RealCUGAN. Use `--processor realcugan` only when
maximum sharpness is wanted and faces/edges get eyeballed first.

libplacebo is **not** in this nixpkgs' video2x build (`Filter
'libplacebo' not found`) — no RAISR/Animeweb upscalers via this route.

Extrapolated to the full 29-min capture at x2: ≈ 4–5 h on the RX 580 —
run it on the R9700 (`--gpu 1` after `gpu-mode game`; expect several
×  faster on RDNA4) as a dedicated session, not beside Strata (475 MB
VRAM free with the LLM resident).

## Notes

* **Paths with spaces + `just`:** just substitutes variadic `{{args}}`
  into the recipe unquoted (a documented just limitation), so a quoted
  `"my file.mpg"` arrives split and footage-clean reports *too many
  positional args* (the error explains it). Either preserve inner
  quotes — `just footage "'/ds-public/Pete DV/Video8/Disneyland
  Paris.mpg'"` — or skip just: `nix build .#footage-kit &&
  ./result/bin/footage-clean ...`.

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
