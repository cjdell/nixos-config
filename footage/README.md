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
# analog PCTV capture (lossless mkv master: crop bars + head-switch band,
# the master's own field-order tag drives the deinterlacer):
just footage --denoise light --grade --crop 700x556+10+2 captures/<file>.mkv
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
flag with its default. Three that earn their keep on tape work:
`--to SEC` (end trim — the cut happens before any stage reads, so a blank
tail is never decoded and the audio is cut with the video; with
`--single-pass` there is no temp file at all — vspipe trims the source clip
and the encoder stops with `-t`), `--single-pass` (VapourSynth straight
into the final encoder: no crf 12 intermediate, one read of a 100+ GB master)
and `--crf 0` with `--codec x264` (bit-exact — see "Lossless?" below).

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
  of the time, and it knows what it is looking at: a **lossless capture
  master** (ffv1/utvideo/uyvy) is trusted outright — its container tag is the
  capture's own declaration, and idet's TFF-vs-BFF vote on this content is
  near a coin-toss (9:10 on test clips). Old `.mpg`s still get the idet
  treatment (it believes `idet` over the container's bogus `bb` — idet found
  TFF=250/BFF=0 on the 2026-11-01 capture and was right). Override with
  `--deint qtgmc|znedi3|eedi3` + `--field tff|bff` when you know better.
  Interlaced sources come out as full-rate 50p, never 25p.
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
  24 for space) and `--codec x265|x264|av1|gpu-*|nvenc-hevc|nvenc-h264`.
  x265 medium on the 5950X ≈ 2.2× realtime; `gpu-h265` offloads VCN to the
  RX 580; `nvenc-hevc` (e.g. the RTX 2060 on kabylakeitx) is the watch-copy
  default: `--crf 16 --preset slow` (→ cq16 p5/tune hq) after QTGMC, whole
  50p features at ~1× realtime — the encode is free, qtgmc is the cost.
* **Stitched/concatenated masters pay a first-open pre-index.** `clean.vsh`
  sources via BestSource (`bs.VideoSource`); capture-station originals carry
  complete cue tables so frames start flowing in seconds, but a master built
  by `ffmpeg -f concat -c copy` forces BestSource to build its lavf index
  first — a full scan of the file (~58 MB/s measured; ~30 min on a 115 GB
  90-minute master) **before the first `frame=` line**. The run is healthy
  during this phase but silent in the log; the proof is `read_bytes` growth
  in `/proc/<vspipe-pid>/io`. Budget the pre-roll when scheduling, or
  render straight from the original parts (per-segment kit runs + concat of
  the HEVC watch copies) if the pre-index cost is not worth paying twice —
  the index lives in the unit's private tmp and does not survive the run.
* **Stitch bookkeeping:** keep segment files on the **NFS share** whenever
  total tape exceeds ~2¼ h — the rawvideo copies (~21 MB/s) fill a 219 GB
  capture-box root otherwise, and an ENOSPC-truncated segment is eaten
  silently by `-f concat` (exit 0, short file). Assert the stitched
  duration against the **sum of probed segment durations**, never a
  hand-added constant (the France run of 2026-11-06 lost a 2000 in the
  sum and gated a perfect master), and make the render gate check both
  duration and seam frames — point-probes alone cannot see a file that
  simply never ends.
* **Dropout mapping at ingest:** the cheap 1-fps `signalstats` scan misses
  dropouts outright (Dell 02 lost two runs and an entire "content" verdict).
  Use a **full-census decode** — every 4th frame (~0.16 s), dark-blue test
  `U-V>80 && Y<120` (the Y gate matters: over-bright blue SKY otherwise
  false-positives by the hundred on airshow/ski footage). Census run edges
  are ±1 sample wide AND multi-run dropout *storms* have ragged pre-roll —
  Dell 02 kept one saturated blue frame behind a 0.2 s guard (storm truth
  began 0.24 s before its first solid census sample). Use a **0.4 s guard**
  and gate every right edge with a per-frame (threshold-loosened, `d>45`)
  window decode, not the census numbers. Also check *to the last frame*:
  an edge sweep ending at `to-0.04` leaves a one-frame blind spot exactly
  where these ragged edges live.
* **Do not trust single-frame `-ss` probes on these rawvideo MKVs** — the
  input seek can land on a different frame than requested (a phantom blue
  frame at P2 t=300 chased through two scripts before a sequential window
  decode proved t=300.0 is clean). Verify every cut edge by decoding a
  ~0.7 s window and filtering frames by **relative** pts — an input `-ss`
  zeroes the output timestamps, so absolute-pts filters silently match
  nothing (the first Dell 02 gate SKIPped every check this way). And note
  a post-render seam sweep on the *watch copy* is the only check that
  catches kept-edge raggedness for free — run it before deleting the
  segment scratch, or a fix means re-cutting every segment.
* **OSD stamps before rendering:** sample the bottom-right ROI every ~2 min
  into one tiled contact sheet per part — Dell 02's stamp was *intermittent*
  (visible ~20 % of samples, dates `17 10 1995`→`24 7 1996`: the tape is
  sessions from months apart, one capture). Then measure the box once with
  a 3× zoom + `drawgrid` ROI grab (40 px rule) and pass it as `--osd-rect`.

## Tuning the deinterlace (fences, pans, camcorder OSD)

Two artifact classes the default qtgmc chain produces on tape, and the
flags that fix them (all default to the historical chain — existing
renders are the default):

* **Periodic detail under a pan** (fence/crib slats, book spines). The
  two fields of a panning shot are shifted horizontally by the pan; MVTools
  must find that vector per block, but on a periodic pattern the *wrong*
  vector — shifted by one bar spacing — costs the same, and Hexes search
  with 32px refine blocks (one block spanning several bars) picks it. The
  wrong vectors are then temporally blended, smearing the slats. Recipe:
  `--me-search 5 --me-searchparam 3 --me-range 32 --me-divide --me-rblk 16
  --deint-degrain 0` — EPZS search (exhaustive-ish, survives periodicity),
  wider range for fast pans (default ~16px/frame via super padding),
  analyse-32-divide-16, single-bar refine blocks, and no temporal degrain
  to smear the misses. Cost: roughly 0.8× realtime instead of ~1.15×.
  `--me-blend 0` adds back field-crispness where vectors are right, but
  combs where they are wrong — try it only if 1 is still too soft.
* **The burned-in camcorder timestamp/date** is a per-field overlay, so
  every temporal pass treats the scene moving behind it as the moving
  subject: digits and background blend into each other. `--osd-rect
  WxH+X+Y` merges the untouched znedi3 bob back over that rect as the very
  last op (after denoise), feathered by `--osd-feather` (default 6px) so
  the seam is invisible in still backgrounds. For these PCTV camcorders
  the bottom-right stamp sits at `--osd-rect 200x52+430+450` (measured on
  the 720×576 frame; check a frame of your own before a long render).
  The protected region loses temporal denoise — that is the trade.

  **Status 2026-11-06:** the robust-ME + `--osd-rect` combination
  (robust-osd) is user-confirmed as the improvement over the default
  chain on the PCTV tapes; full-tape re-renders with it are on hold
  until the tapes/minutes are named. Samples kept in
  `/ds-public/pctv-deinterlaced/AB/` on the kabylakeitx NAS mount.
* **Colour tags:** output is stamped bt709; `--source-color` keeps the
  source's (broken) tags instead. Mislabelled `bt2020c` sources get an
  automatic normalising pass — that's a fix, not a bug. Note that the restamp
  is **not a label**: `-colorspace bt709` makes ffmpeg insert a real
  bt601→bt709 matrix (measured 22.7 dB luma against untouched frames), so a
  `--crf 0` lossless encode keeps the source's own tags and says so. Stamping
  without converting is only ever a declaration, and declaring an SD tape
  master bt709 would be a lie.
* **Lossless?** `--codec x264 --crf 0` is genuinely bit-exact: x264 refuses
  lossless outside High 4:4:4 Predictive (`high422` + `-qp 0` errors), so the
  profile is picked from the output format and the source's 4:2:2 is kept
  (`high444` carries chroma_format_idc=2 — verified byte-identical, and
  decoding it is software-only: no hardware block does 4:2:2/4:4:4 H.264).
  Pair it with `--single-pass`, and with `--to SEC` to drop a blank tail in
  the same read. HEVC has no 8-bit 4:2:2 lossless profile, so `--crf 0` with
  anything but x264 is refused.

### Recipes that are known good

```sh
# PCTV lossless master (ffv1/utvideo .mkv) -> clean 50p HEVC:
just footage --denoise light --grade --crop 700x556+10+2 captures/x.mkv

# ...deinterlaced *only*, kept as a bit-exact 4:2:2 H.264 master for later
# processing: --single-pass so nothing is squeezed twice, --to to drop a blank
# tail while the master is still being read once, PCM audio stream-copied
# (that is why the output is .mkv — PCM into .mp4 becomes 'ipcm'):
just footage --denoise none --codec x264 --crf 0 --single-pass \
  --to 5340 captures/Disney.mkv Disney-deinterlaced.mkv

# ...same, upscaled x2 for the collection, on the RX 580 (~4.5 h per 29 min):
just footage --denoise light --grade --crop 700x556+10+2 \
  --upscale 2 captures/x.mkv       # add --gpu 1 when the R9700 lease is free

# legacy PCTV MPEG capture (.mpg) -> clean 50p HEVC (the 2026-11-01 render):
just footage --deint qtgmc --denoise light --grade --crop 700x556+10+2 captures/x.mpg

# digital travel clip: denoise banding, sharper, small file:
just footage --denoise standard --deband --crf 22 n265.mp4

# SD DVD rip to a crisp 2x with the sharper net:
just footage --deint auto --denoise light --upscale 2 --processor realcugan vob.mkv
```

## Feeding PCTV lossless masters into the pipeline (since 2026-11-02)

The PCTV 320cx capture station (`pctv-linux/`, the macbook-pro-2009) no
longer archives as MPEG-2. `--master ffv1|utvideo|uyvy` writes a **lossless
Matroska master**: `pctv-cap-<date>.mkv`, 720×576 `yuv422p` (`uyvy422` for
`uyvy`), 25i top-field-first, audio `pcm_s16le` 48k. It arrives over
`sftp`/the shared directory and goes straight into the pipeline — **no
pre-conversion step exists or is needed**:

```sh
just probe    captures/pctv-cap-x.mkv     # recognises the master, reads field flags
just footage  --test 12 --denoise light --grade --crop 700x556+10+2 captures/pctv-cap-x.mkv /tmp/t.mp4
just footage  --denoise light --grade --crop 700x556+10+2 captures/pctv-cap-x.mkv
```

* **Field order comes from the container, not from idet.** The masters tag
  themselves `tb` (Matroska's spelling of coded-top-first) and ffv1/uyvy also
  stamp every decoded frame interlaced+TFF. `--deint auto` now *trusts*
  master codecs instead of falling back to idet — deliberate: on this content
  idet's parity vote measured 9:10 on synthetic clips that differed only in
  field order (pctv docs §10.3), so "which field is first" must come from the
  capture, which knows it by derivation (BT.656 field 1 = top, like DV-PAL).
  **utvideo** masters carry no per-frame flags at all — players show them as
  25p unless told; footage-clean still deinterlaces them correctly from the
  container tag, and `pctv-field-order --relabel` (on the Mac) fixes playback.
* **Coded order ≠ temporal order: measure before raw bobbing.** The archive
  `Disney.mkv` (tagged `tb`, coded top first) plays correctly with **bff**
  bobs: the cross-frame field diff (bottom field of frame *n* vs top field of
  *n+1*) measured ~3× the same-frame diff (PSNR 14.1 vs 17.4 dB, two
  timestamps), and a `parity=tff` bob alternates consecutive-frame diffs —
  visible as field-rate jitter, "double vision" — while `parity=bff` is
  uniform. QTGMC *masks* a coded/temporal mix-up (its motion-compensated
  reconstruction re-interpolates the true instants; the master measured
  uniform and looks clean), so a good QTGMC master is NOT proof the flag is
  right — raw bobs (`bwdif*`, `yadif`, DDD) expose it. Cheap test on any
  interlaced master:

  ```sh
  T=7384            # somewhere with real motion
  ffmpeg -ss $T -i master.mkv -frames:v 2 -vf field=type=top    T%d.png
  ffmpeg -ss $T -i master.mkv -frames:v 2 -vf field=type=bottom B%d.png
  ffmpeg -i B1.png -i T1.png -filter_complex psnr -f null -   # 20 ms baseline
  ffmpeg -i B1.png -i T2.png -filter_complex psnr -f null -   # ≈ baseline → tff;
                                                              # clearly lower → bff
  ```

* **Audio:** masters hold lossless PCM. Stream-copying PCM into an `.mp4`
  lands it as `ipcm`, which most players cannot read, so the *final* encode
  transcodes it to aac 192k by default (`--acodec alac` keeps it lossless,
  `--acodec copy` forces ipcm). The master is never touched — it is the
  archive, keep it.
* **Raw files:** a headerless `.uyvy` is not a pipeline input; `footage-probe`
  prints the one-liner that wraps it losslessly into an ffv1 MKV. A raw
  **BT.656** dump (`pctv_probe stream > x.bin`) is a *diagnostic* format with
  EAV/SAV sync words — it needs the monitor's deframer, never the pipeline.

### Why not convert to lossless H.264 first? (settled by measurement)

Asked and answered 2026-11-02:

* **The capture box cannot write it:** x264 `-qp 0` measured **0.71× realtime**
  on the macbook-pro-2009 (`-crf 12`: 0.48×) — it would drop pictures during
  capture; FFV1 runs 4.5× and never rate-controls. Measured table:
  `pctv-linux/README.md` "Which master to write".
* **On this box it decodes *slower* than the master** (720×576, 150 f,
  5950X): `x264 -qp 0` 13.3× single-thread / **47.6× multithread**, vs
  ffv1 15.9×/**130×**, utvideo 54.6×/131×. The serial CABAC + frame
  dependencies of a lossless x264 stream are worse pipeline food than
  intra-only FFV1.
* It *would* be bit-exact (verified: `-qp 0 -pix_fmt yuv422p` round-trips
  `framemd5`-identical, High 4:4:4 profile), so this is not a lossiness
  argument — it is the generation argument: **the pipeline already produces
  exactly that intermediate** (stage 1 emits x264 crf 12, visually lossless)
  *after* crop/deint/denoise have made the frames worth encoding. Converting
  first would double-encode every frame, cost hours, and still leave the
  FFV1 master as the thing you trust.

One master in, one cleaned file out; the FFV1 MKV stays the archival master
forever (4 MB/s of real tape ≈ 7 GB per 29-min tape).

## How the standard workflow maps onto this kit

The usual advice is *FFmpeg + VapourSynth + QTGMC → BM3D/KNLMeans →
Real-ESRGAN via vs-mlrt → FFmpeg encode*. On this machine, with this
pinned nixpkgs, it lands like this:

| step              | classic advice                | what this kit actually runs                                |
| ----------------- | ----------------------------- | ---------------------------------------------------------- |
| deinterlace       | QTGMC (Avisynth/havsfunc)     | QTGMC-style chain built from the packaged parts: znedi3/eedi3 field-interpolation → MVTools FlowInter → MDegrain (`--deint qtgmc`). Real QTGMC.py needs fmtconv + havsfunc, which nixpkgs does not carry — the substitution is honest and close (`slower` preset minus the source-match passes). `bwdif` via plain FFmpeg is the fast fallback. |
| denoise           | BM3D / KNLMeansCL / SMDegrain | MDegrain (MVTools) temporal denoise, 4 strengths (`--denoise light..stronger`) + chroma BoxBlur. BM3D/KNLMeans VS plugins aren't packaged; motion-compensated averaging is the right tool for exactly the noise these files have (per-frame sensor noise + compression banding). |
| tape artifacts    | FixChromaBleeding etc.        | the analog path today is the PCTV **lossless master** (ffv1/utvideo/uyvy `.mkv`, see the section above; MPEG-2 `.mpg`s still work): crop (pillar bars + head-switching band, `--crop 700x556+10+2`), `--deint qtgmc`, `--denoise light` and `--grade` handle combing, tape noise and faded colour; verified on `captures/pctv-cap-20261101-210236.mpg` and on master-shaped `.mkv`s 2026-11-02. Composite-level fixes (color bleed, WRNAGS) would need avs-xf/fmtconv vendored first; noted under "extension points". |
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
