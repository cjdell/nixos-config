#!/usr/bin/env bash
# footage-clean — one-command video cleanup pipeline.
#
#   probe (interlacing / bad color tags / GPU lease)
#     -> VapourSynth: crop, deinterlace (znedi3/eedi3/QTGMC-style), MDegrain
#     -> optional GPU stages: RealESRGAN upscale, RIFE interpolation
#        (video2x on Vulkan)
#     -> FFmpeg encode (libx265 default; SVT-AV1 / x264 / VAAPI H.265 /
#        NVIDIA NVENC HEVC+H.264 also available; audio stream-copied — except
#        PCM capture masters into .mp4, which become aac; --acodec overrides).
#
# Every tool below is an absolute store path baked in by kit.nix, so the
# script needs no PATH beyond the basics (bash, coreutils, awk).

set -euo pipefail

VSPIPE=@vspipe@
VIDEO2X=@video2x@
REALESRGAN=@realesrgan@
REALESRGAN_MODELS=@realesrganModels@
FFMPEG=@ffmpeg@
FFPROBE=@ffprobe@
PY=@python3@
CLEANVSH=@cleanvsh@
export FC_FFPROBE=$FFPROBE

usage() {
  cat <<'EOF'
footage-clean — denoise/deinterlace/upscale/encode camera & tape footage

USAGE
  footage-clean [options] INPUT [OUTPUT]

Pipeline stages (each optional, run in this order):
  1. probe      interlacing + color-tag sanity (always runs)
  2. clean      crop -> deinterlace -> temporal denoise (VapourSynth)
  3. upscale    RealESRGAN / RealCUGAN on GPU via Vulkan (video2x)
  4. interp     RIFE 2x frame interpolation on GPU (video2x)
  5. encode     FFmpeg final encode + original audio, sane bt709 tags

OPTIONS
  -o, --output FILE   output file (default: <input>-cleaned.mp4)
  --deint MODE        auto|off|znedi3|eedi3|nnedi3cl|qtgmc        (default auto)
                        auto = QTGMC-style chain if interlacing is detected,
                               else off
                        znedi3/eedi3/nnedi3cl = 2x-rate field interpolation
                        qtgmc = that + motion-compensated degrain
  --field ORDER       tff|bff field order (default: detected, else tff)
  --denoise LEVEL     none|light|standard|strong|stronger       (default standard)
  --crop WxH+X+Y      crop first (overscan, head-switch noise, bars)
  --me-search N       qtgmc motion search algo 0..5 (default 3 = Hexes).
                      Periodic detail — fences, book spines, crib slats —
                      makes Hexes lock a neighbour-period vector; 5 (EPZS)
                      or 4 (UMH) resist it.
  --me-searchparam N  search log-step (default 2; use 3 with EPZS)
  --me-range N        search range px (default ~16 via super padding; use
                      24-32 for fast camera pans)
  --me-divide         analyse 32x32 then divide to 16x16 (QTGMC 'divide')
  --me-rblk N         refine block size (default 32; 16 = at most one fence
                      bar per block — matters with periodic detail)
  --me-blend 0|1      FlowInter field blend (default 1; 0 = crisper on pans,
                      combs where vectors fail)
  --deint-degrain 0|1 temporal degrain after the mc deinterlace (default 1;
                      0 = wrong vectors cannot smear over time)
  --osd-rect WxH+X+Y  keep the PURE spatial bob inside this rect at the end
                      of the chain: for a burned-in camcorder timestamp,
                      which temporal passes otherwise smear into the digits
  --osd-feather N     feather px on the --osd-rect edge (default 6)
  --upscale N         2|3|4  neural upscale on the GPU
  --processor P       realesrgan (default) | realcugan
  --model NAME        model for the processor:
                        realesrgan: realesr-animevideov3 (default, best speed/
                                    quality on video) | realesrgan-plus-anime |
                                    realesrgan-plus (x4 quality, ~30x slower)
                        realcugan:  models-pro (default, sharper, can
                                    over-texture skin/faces) | models-se
  --interp            RIFE 2x frame interpolation (e.g. 25p -> 50p)
  --gpu N             video2x Vulkan device index for stages 3-4 (default 0;
                      enumerate with 'nix run .#footage-kit.passthru.video2xPatched -- -l')
  --codec C           x265|x264|av1|gpu-h265|gpu-h264 (VAAPI, AMD/Intel) |
                      nvenc-hevc|nvenc-h264 (NVIDIA)   (default x265)
                        nvenc-*: GPU encode, frames uploaded by NVENC itself;
                        on Turing HEVC is clearly the better engine (its H.264
                        NVENC block lags a generation). 8-bit 4:2:0 watch
                        profile; NVENC has no 4:2:2 and 4:4:4 is
                        software-decode-only, so masters stay on the CPU codecs.
  --acodec A          auto|copy|aac|alac                        (default auto)
                        auto: stream-copy, except PCM masters (ffv1/utvideo/
                              uyvy) going to .mp4, which become aac 192k —
                              stream-copied PCM lands in mp4 as 'ipcm', which
                              most players cannot read. The master stays PCM.
  --crf N             quality: CPU codecs use crf, VAAPI -global_quality,
                      NVENC -cq with -rc vbr -b:v 0 (default 20; lower =
                      better; 16-18 is "high quality lossy" territory for
                      nvenc-* on grainy tape). crf 0 = LOSSLESS for x264:
                      the encode switches to -qp 0 with the source's own pixel
                      format (see --pixfmt), because x264 only does lossless in
                      the High 4:4:4 Predictive profile — 'high422' + -qp 0 is
                      rejected outright ("high422 profile doesn't support
                      lossless") and forcing yuv444p instead would upsample a
                      4:2:2 capture. Verified byte-identical round trip:
                      -profile:v high444 -qp 0 -pix_fmt yuv422p.
  --pixfmt FMT        output pixel format for CPU codecs (default: keep the
                      source's when lossless, else ffmpeg's choice)
  --preset P          x265/x264 speed preset (default medium). nvenc-* maps
                      the same vocabulary onto NVENC's p0..p7 (fast→p2,
                      medium→p4, slow→p5, slower→p6, veryslow→p7) and always
                      adds -tune hq.
  --vaapi-dev PATH    /dev/dri/renderD12x for --codec gpu-* (default renderD128)
  --deband            ffmpeg deband pass (banded skies/gradients)
  --grade             analog colour refresh (eq: saturation 1.18, contrast 1.04)
  --sharpen A         mild unsharp after clean, e.g. 0.4 (default off)
  --test N            process only N seconds (from --from) — test first!
  --from SEC          start offset for --test / --to (default 0)
  --to SEC            stop at SEC seconds — trims the tail off the source
                      (blank tape, dropout, the operator's hand on the deck).
                      Frames after SEC are never read, so unlike trimming the
                      finished render this is one pass, and audio is cut with
                      the video. With --single-pass there is no temp file at
                      all; otherwise the kept range is stream-copied once
                      (start snaps to the previous keyframe) into $TMPDIR.
  --single-pass       pipe VapourSynth straight into the final encoder instead
                      of writing the crf 12 intermediate. One read of the
                      source, and — the reason it exists — a lossless final
                      encode stops being lossless-of-lossy. Needs no GPU stage
                      (those need a file between the stages).
  --threads N         worker threads (default: all cores)
  --source-color      keep source color tags instead of tagging bt709
  --keep-temp         keep intermediate files (path printed at exit)
  --dry-run           print the plan and exit

EXAMPLES
  footage-probe cam.mp4                      # what is this file?
  footage-clean --test 12 cam.mp4            # short test render first!
  footage-clean --denoise standard --deband cam.mp4 cam-cleaned.mp4
  footage-clean --deint qtgmc --denoise light vhs-capture.mp4
  footage-clean --denoise none --upscale 2 --interp lowres.mp4
  # deinterlaced lossless H.264 master off a capture master, tail trimmed:
  # one pass, no crf 12 intermediate, 4:2:2 kept, PCM audio copied
  footage-clean --deint auto --denoise none --codec x264 --crf 0 \
    --single-pass --to 1750 Disney.mkv Disney-deint.mkv
  # the same tape as a high-quality watch copy on the NVIDIA card: QTGMC on
  # the CPU, NVENC HEVC for the encode — the GPU never deinterlaces here,
  # only compresses. QTGMC keeps the kit's coded-order trust (it measured
  # clean); bff matters only for RAW bobs — see the README field test.
  footage-clean --deint auto --denoise none --codec nvenc-hevc --crf 16 \
    --preset slow --single-pass --source-color \
    --to 7385.88 Disney.mkv Disney-watch.mkv

  # ...same, but tuned for a tape with fast pans over periodic detail
  # (fences/slats) and a burned-in bottom-right timestamp:
  footage-clean --deint auto --denoise none --codec nvenc-hevc --crf 16 \
    --preset slow --single-pass --source-color \
    --me-search 5 --me-searchparam 3 --me-range 32 --me-divide --me-rblk 16 \
    --deint-degrain 0 --osd-rect 200x52+430+450 \
    tape.mkv tape-watch.mkv
EOF
}

# ---------------------------------------------------------------- args -----
IN=""
OUT=""
DEINT=auto
FIELD=auto
DENOISE=standard
CROP=""
UPSCALE=1
PROCESSOR=realesrgan
MODEL=realesr-animevideov3
MODEL_SET=0
INTERP=0
GPUDEV=""
CODEC=x265
A_MODE=auto
CRF=20
PIXFMT_OUT=""
PRESET=medium
VAAPI_DEV=/dev/dri/renderD128
DEBAND=0
GRADE=0
SHARPEN=""
TEST=0
FROM=0
TO=0
SINGLE_PASS=0
THREADS=""
SOURCE_COLOR=0
KEEP_TEMP=0
DRY=0
# qtgmc ME tuning + OSD protection (defaults = the historical chain)
ME_SEARCH=3
ME_SEARCHPARAM=2
ME_RANGE=0
ME_DIVIDE=0
ME_BLEND=1
ME_RBLK=32
DEINT_DEGRAIN=1
OSD_RECT=""
OSD_FEATHER=6

while [ $# -gt 0 ]; do
  case "$1" in
    --deint) DEINT=$2; shift 2 ;;
    --field) FIELD=$2; shift 2 ;;
    --denoise) DENOISE=$2; shift 2 ;;
    --crop) CROP=$2; shift 2 ;;
    --upscale) UPSCALE=$2; shift 2 ;;
    --processor) PROCESSOR=$2; shift 2 ;;
    --model) MODEL=$2; MODEL_SET=1; shift 2 ;;
    --interp) INTERP=1; shift ;;
    --gpu) GPUDEV=$2; shift 2 ;;
    --codec) CODEC=$2; shift 2 ;;
    --acodec) A_MODE=$2; shift 2 ;;
    --crf) CRF=$2; shift 2 ;;
    --pixfmt) PIXFMT_OUT=$2; shift 2 ;;
    --preset) PRESET=$2; shift 2 ;;
    --vaapi-dev) VAAPI_DEV=$2; shift 2 ;;
    --deband) DEBAND=1; shift ;;
    --grade) GRADE=1; shift ;;
    --sharpen) SHARPEN=$2; shift 2 ;;
    --test) TEST=$2; shift 2 ;;
    --from) FROM=$2; shift 2 ;;
    --to) TO=$2; shift 2 ;;
    --single-pass) SINGLE_PASS=1; shift ;;
    --me-search) ME_SEARCH=$2; shift 2 ;;
    --me-searchparam) ME_SEARCHPARAM=$2; shift 2 ;;
    --me-range) ME_RANGE=$2; shift 2 ;;
    --me-divide) ME_DIVIDE=1; shift ;;
    --me-blend) ME_BLEND=$2; shift 2 ;;
    --me-rblk) ME_RBLK=$2; shift 2 ;;
    --deint-degrain) DEINT_DEGRAIN=$2; shift 2 ;;
    --osd-rect) OSD_RECT=$2; shift 2 ;;
    --osd-feather) OSD_FEATHER=$2; shift 2 ;;
    --threads) THREADS=$2; shift 2 ;;
    -o|--output) OUT=$2; shift 2 ;;
    --source-color) SOURCE_COLOR=1; shift ;;
    --keep-temp) KEEP_TEMP=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "footage-clean: unknown option $1" >&2; usage >&2; exit 2 ;;
    *) if [ -z "$IN" ]; then IN=$1; elif [ -z "$OUT" ]; then OUT=$1
       else EXTRA="${EXTRA:+$EXTRA }$1"; POS_EXTRA=1; fi
       shift ;;
  esac
done
if [ "${POS_EXTRA:-0}" = 1 ]; then
  echo "footage-clean: too many positional args (extra words: $EXTRA)" >&2
  echo "  A path with spaces arrived split. 'just' substitutes variadic {{args}}" >&2
  echo "  unquoted — double-quote inner quotes:" >&2
  echo "    just footage --upscale 2 \"'my file.mpg'\"" >&2
  echo "  or bypass just entirely: ./result/bin/footage-clean (after nix build .#footage-kit)" >&2
  exit 2
fi

[ -n "$IN" ] || { usage >&2; exit 2; }
[ -f "$IN" ] || { echo "footage-clean: no such file: $IN" >&2; exit 1; }
IN=$(realpath -- "$IN")
[ -n "$OUT" ] || OUT="${IN%.*}-cleaned.mp4"
 [ -n "$THREADS" ] || THREADS=$(nproc)
if [ "$PROCESSOR" = realcugan ] && [ "$MODEL_SET" = 0 ]; then
  MODEL=models-pro   # sensible default for the realcugan processor
fi
case "$PROCESSOR" in realesrgan|realcugan) ;;
  *) echo "footage-clean: --processor must be realesrgan|realcugan" >&2; exit 2 ;;
esac

# --to is an end trim, --test a bounded sample from --from. Both cut the source
# up before any stage sees it, so they are mutually exclusive, and --to has to
# point past --from or the stream copy gets a negative -t and fails obscurely.
if [ "$TO" != 0 ]; then
  if ! awk -v f="$FROM" -v t="$TO" 'BEGIN{exit !(t>f)}'; then
    echo "footage-clean: --to $TO must be greater than --from $FROM" >&2
    exit 2
  fi
  if [ "$TEST" != 0 ]; then
    echo "footage-clean: --to and --test cannot be combined (--test N already bounds the length)" >&2
    exit 2
  fi
fi

# ---------------------------------------------------------------- probe ----
IFS=$'\t' read -r WIDTH HEIGHT FPS FRATE FIELD_ORDER CSPACE CMATRIX PRIM TRC \
    PIXFMT BITRATE DUR VCODEC ACODEC < <($PY - "$IN" <<'PYEOF'
import json, os, subprocess, sys
try:
    data = json.loads(subprocess.check_output([
        os.environ["FC_FFPROBE"], "-v", "error",
        "-show_entries",
        "stream=codec_type,codec_name,width,height,r_frame_rate,field_order,"
        "pix_fmt,color_space,color_matrix,color_primaries,color_transfer,bit_rate",
        "-show_entries", "format=duration", "-of", "json", sys.argv[1],
    ], stderr=subprocess.DEVNULL))
except subprocess.CalledProcessError:
    sys.exit("footage-clean: ffprobe cannot read this file. A headerless raw "
             "stream (.uyvy/.yuv/BT.656 dump) must be wrapped into a master "
             "first — footage-probe prints the exact ffmpeg command.")
s = next(x for x in data["streams"] if x.get("codec_type") == "video")
a = next((x for x in data["streams"] if x.get("codec_type") == "audio"), {})
fmt = data.get("format", {})
def g(k, d="?"):
    return s.get(k) or d
num, _, den = s["r_frame_rate"].partition("/")
fps = float(num) / float(den or 1)
print("\t".join(map(str, (
    s["width"], s["height"], int(round(fps)), s["r_frame_rate"],
    g("field_order"), g("color_space"), g("color_matrix"),
    g("color_primaries"), g("color_transfer"), g("pix_fmt"),
    int(s.get("bit_rate") or fmt.get("bit_rate") or 0),
    float(fmt.get("duration") or 0), s["codec_name"],
    a.get("codec_name") or "",
))))
PYEOF
)

# A lossless capture master (pctv-linux --master ffv1|utvideo|uyvy): every
# sample is exact and the container tag is the capture's own declaration, so
# its field-order metadata is trustworthy in a way an old MPEG-2 .mpg's is not.
MASTER=0
case "$VCODEC" in
  ffv1|ffvhuff|huffyuv|utvideo|rawvideo|qtrle) MASTER=1 ;;
esac

DEINT_APPLIED=off
DETECT_NOTE="not checked"
if [ "$DEINT" = auto ]; then
  TRUST=0
  case "$FIELD_ORDER" in
    tt|bt) TRUST=1 ;;                      # explicit container flags
    tb|bb) # tb is how ffprobe spells a Matroska master's coded-top-first tag;
           # bb for MPEG-2 .mpg is the ffmpeg probe quirk and lies, so only
           # lossless masters get believed here. NOTE: the first letter is the
           # CODED order; the temporal order can differ (Disney.mkv bobs
           # correctly with bff). Fine for QTGMC, which re-interpolates true
           # instants; run the README's PSNR field test before raw-bobbing.
      [ "$MASTER" = 1 ] && TRUST=1 ;;
  esac
  if [ "$TRUST" = 1 ]; then
    DEINT_APPLIED=qtgmc
    # first letter of the flag = which field is coded first = what a
    # deinterlacer must assume (trusts coded == temporal; see the caveat above).
    if [ "$FIELD" = auto ]; then
      case "$FIELD_ORDER" in t*) FIELD=tff ;; *) FIELD=bff ;; esac
    fi
    if [ "$MASTER" = 1 ]; then
      DETECT_NOTE="container flags field_order=${FIELD_ORDER} -> interlaced (lossless master: trusted, no idet coin-toss)"
    else
      DETECT_NOTE="container flags field_order=${FIELD_ORDER} -> interlaced"
    fi
  else
    t0=$(awk "BEGIN{if ($DUR > 40) printf \"%.0f\", $DUR / 4; else print 0}")
    idet_line=$($FFMPEG -hide_banner -v info -ss "$t0" -t 10 -i "$IN" -an \
                  -vf idet -f null - 2>&1 | grep -E 'Multi frame detection' | tail -1 || true)
    read -r idet_tff idet_bff idet_prog < <($PY - <<PYEOF
import re
line = """$idet_line"""
def n(pat):
    m = re.search(pat, line)
    return int(m.group(1)) if m else 0
print(n(r"TFF:\s*(\d+)"), n(r"BFF:\s*(\d+)"), n(r"Progressive:\s*(\d+)"))
PYEOF
)
    inter=$((idet_tff + idet_bff))
    if [ "$inter" -ge 3 ] && [ "$inter" -gt "$(( (inter + idet_prog) / 20 ))" ]; then
      DEINT_APPLIED=qtgmc
      [ "$FIELD" = auto ] && FIELD=$([ "$idet_tff" -ge "$idet_bff" ] && echo tff || echo bff)
      DETECT_NOTE="idet TFF=$idet_tff BFF=$idet_bff P=$idet_prog -> interlaced"
    else
      DETECT_NOTE="idet TFF=$idet_tff BFF=$idet_bff P=$idet_prog -> progressive"
    fi
  fi
elif [ "$DEINT" = off ]; then
  DETECT_NOTE=off
else
  DEINT_APPLIED=$DEINT
fi
[ "$FIELD" = auto ] && FIELD=tff

WARN=""
if [ "$CMATRIX" = bt2020c ]; then
  WARN="
  ! source is tagged matrix=bt2020c (constant luminance) — no consumer camera
    writes that; almost certainly a bad tag. swscale/zimg refuse to convert it;
    this pipeline decodes it normally and tags the output bt709."
fi

echo "footage-clean: $IN"
echo "  ${WIDTH}x${HEIGHT} @ ${FRATE} fps, ${PIXFMT}, ${DUR}s, ${BITRATE} bps"
echo "  color: space=${CSPACE} matrix=${CMATRIX} primaries=${PRIM} transfer=${TRC} field_order=${FIELD_ORDER}"
echo "  deint: ${DEINT} -> ${DEINT_APPLIED} (${FIELD}); ${DETECT_NOTE}"
echo "  denoise=${DENOISE} upscale=x${UPSCALE} (${MODEL}) interp=${INTERP} codec=${CODEC} crf=${CRF}"
[ -n "$WARN" ] && printf '%s\n' "$WARN"

if { [ "$UPSCALE" != 1 ] || [ "$INTERP" = 1 ]; } &&
   command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet strata 2>/dev/null; then
  echo "  note: strata.service is running; GPU stages share the R9700 with the LLM (fine, ncnn tiles small). Use --gpu N to pin another device."
fi

# ---------------------------------------------------------------- plan -----
NEED_VS=0
if [ "$DEINT_APPLIED" != off ] || [ "$DENOISE" != none ] || [ -n "$CROP" ]; then
  NEED_VS=1
fi
# Bad matrix tags (bt2020c) survive video2x's remux and then poison the
# final encode's colour-tag restamp (swscale/zimg refuse bt2020c input).
# A no-filter VapourSynth pass re-encodes with clean tags, so force it.
TAGFIX_NEEDED=0
if [ "$CMATRIX" = bt2020c ] || [ "$CSPACE" = bt2020c ]; then
  TAGFIX_NEEDED=1
  if [ "$NEED_VS" = 0 ]; then
    echo "footage-clean: source has bt2020c tags; forcing a VapourSynth pass to normalise them (anything downstream that converts colour will choke on that tag)"
    NEED_VS=1
  fi
fi

VF=""
[ "$DEBAND" = 1 ] && VF="${VF:+$VF,}deband=1thr=0.006:2thr=0.006:3thr=0.006:4thr=0.006:r=16"
[ "$GRADE" = 1 ] && VF="${VF:+$VF,}eq=saturation=1.18:contrast=1.04"
[ -n "$SHARPEN" ] && VF="${VF:+$VF,}unsharp=5:5:${SHARPEN}"

# --------------------------------------------------------------- encoder ---
# Decided before any stage runs: --single-pass feeds these flags straight to
# VapourSynth's ffmpeg, and the plan printed below has to say what will really
# happen.

# --crf 0 means LOSSLESS. x264 refuses lossless outside the High 4:4:4
# Predictive profile (`-profile:v high422 -qp 0` dies with "high422 profile
# doesn't support lossless"), which is why the profile follows the output
# pixel format below instead of being hardcoded to 'high' — and a 4:2:2
# capture is kept at 4:2:2 rather than upsampled to 4:4:4 to satisfy it: High
# 4:4:4 Predictive carries chroma_format_idc=2, and `-profile:v high444 -qp 0
# -pix_fmt yuv422p` round-trips byte-identical (verified with ffmpeg 9.0.2 by
# decoding and cmp'ing against the raw source). HEVC has no 8-bit 4:2:2
# lossless profile and VAAPI/SVT have no lossless at all, so those are
# refused rather than quietly downgraded.
LOSSLESS=0
if [ "$CRF" = 0 ]; then
  if [ "$CODEC" = x264 ]; then
    LOSSLESS=1
  else
    echo "footage-clean: --crf 0 is only implemented for --codec x264; $CODEC cannot do lossless" >&2
    exit 2
  fi
fi

# Colour: the default restamp to bt709 is *not* a label. ffmpeg treats
# -colorspace as a requested conversion and inserts a bt601->bt709 matrix —
# measured against untouched frames: PSNR y 22.7 / u 28.5 / v 32.6 dB, i.e.
# real pixel changes, not rounding. Declaring the colour on the *input*
# instead does stamp the tags and stays bit-exact, but that mislabels an SD
# tape master, whose true matrix is the bt601/SMTE-170M its own (unspecified)
# tags already imply. So a lossless encode keeps the source's tags.
COLOR=()
if [ "$SOURCE_COLOR" = 0 ] && [ "$LOSSLESS" = 0 ]; then
  COLOR=(-colorspace bt709 -color_primaries bt709 -color_trc bt709)
elif [ "$LOSSLESS" = 1 ] && [ "$SOURCE_COLOR" = 0 ]; then
  echo "footage-clean: lossless => keeping the source's colour tags (space=${CSPACE} matrix=${CMATRIX} primaries=${PRIM} transfer=${TRC}): a bt709 restamp is itself a colour conversion and would undo it"
fi
COLOR_DESC=bt709
if [ "${#COLOR[@]}" = 0 ]; then COLOR_DESC=source; fi

# Output pixel format: --pixfmt wins; else a lossless encode keeps the source's
# format so it cannot silently subsample (that is the whole point); else
# nothing is passed and libx264's yuv420p default applies, as before.
PIXFMT_EFF=$PIXFMT_OUT
if [ -z "$PIXFMT_EFF" ] && [ "$LOSSLESS" = 1 ]; then PIXFMT_EFF=$PIXFMT; fi
[ "$PIXFMT_EFF" = "?" ] && PIXFMT_EFF=""
# A capture master often carries a PACKED chroma layout — UYVY is what every
# DV/VHS USB bridge emits — and ffprobe reports that name as the source pix_fmt.
# x264 cannot encode it (planar inputs only), but the distinction is moot by
# the time frames reach the encoder: vspipe's y4m has already delivered them
# planar. So translate the name and keep the format's identity (4:2:2 stays
# 4:2:2 — which is what makes the lossless claim honest in the first place).
case "$PIXFMT_EFF" in
  uyvy422|uyvy422be|vuy422|yuyv422|yvyu422|nv16|nv61) PIXFMT_EFF=yuv422p ;;
  nv12|nv21) PIXFMT_EFF=yuv420p ;;
esac
# NVENC speaks nv12/p010le, not yuv420p/yuv422p — and silently fails the
# negotiation otherwise, so pin the default rather than leaving it empty.
case "$CODEC" in
  nvenc-*)
    [ -z "$PIXFMT_EFF" ] && PIXFMT_EFF=nv12
    case "$PIXFMT_EFF" in yuv420p) PIXFMT_EFF=nv12 ;; yuv420p10le) PIXFMT_EFF=p010le ;; esac ;;
esac
case "$PIXFMT_EFF" in
  "") PROF=high ;;
  yuv444*|gbrp*) PROF=high444 ;;
  *422*) if [ "$LOSSLESS" = 1 ]; then PROF=high444; else PROF=high422; fi ;;
  *) if [ "$LOSSLESS" = 1 ]; then PROF=high444; else PROF=high; fi ;;
esac

# --preset speaks x264/x265; NVENC answers to p0 (fastest) .. p7 (best).
NVENC_PRESET=p4
case "$PRESET" in
  ultrafast)                    NVENC_PRESET=p1 ;;
  superfast|fast|veryfast)      NVENC_PRESET=p2 ;;
  mediumfast|medium)            NVENC_PRESET=p4 ;;
  slow)                         NVENC_PRESET=p5 ;;
  slower)                       NVENC_PRESET=p6 ;;
  veryslow|placebo)             NVENC_PRESET=p7 ;;
esac

VFARGS=()
case "$CODEC" in
  x265) ENC=(-c:v libx265 -preset "$PRESET" -crf "$CRF"
             -x265-params "log-level=none" -tag:v hvc1) ;;
  x264) if [ "$LOSSLESS" = 1 ]; then
          ENC=(-c:v libx264 -preset "$PRESET" -qp 0)
        else
          ENC=(-c:v libx264 -preset "$PRESET" -crf "$CRF")
        fi
        ENC+=(-profile:v "$PROF") ;;
  av1)  ENC=(-c:v libsvtav1 -crf "$CRF" -preset 8 -svtav1-params "lp=$THREADS") ;;
  gpu-h265)
    ENC=(-init_hw_device vaapi=va:"$VAAPI_DEV" -filter_hw_device va
         -c:v hevc_vaapi -rc_mode CQP -global_quality "$CRF" -tag:v hvc1)
    VF="${VF:+$VF,}format=nv12,hwupload" ;;
  gpu-h264)
    ENC=(-init_hw_device vaapi=va:"$VAAPI_DEV" -filter_hw_device va
         -c:v h264_vaapi -rc_mode CQP -global_quality "$CRF")
    VF="${VF:+$VF,}format=nv12,hwupload" ;;
  # NVIDIA NVENC. Frames arrive from vspipe in system memory and NVENC
  # uploads them itself, so — unlike the VAAPI codecs — no hwupload filter.
  nvenc-hevc)
    ENC=(-c:v hevc_nvenc -preset "$NVENC_PRESET" -tune hq -rc vbr -cq "$CRF" -b:v 0 -tag:v hvc1) ;;
  nvenc-h264)
    ENC=(-c:v h264_nvenc -preset "$NVENC_PRESET" -tune hq -rc vbr -cq "$CRF" -b:v 0) ;;
  *) echo "footage-clean: unknown codec $CODEC" >&2; exit 2 ;;
esac
[ -n "$PIXFMT_EFF" ] && ENC+=(-pix_fmt "$PIXFMT_EFF")
[ -n "$VF" ] && VFARGS=(-vf "$VF")

# Audio: auto = copy, but a PCM master (pctv-linux lossless mkv) written into
# an .mp4 as-is lands there as 'ipcm', which most players cannot demux. Encode
# that case to aac; the master keeps its PCM. mkv/mov outputs may hold PCM.
case "$A_MODE" in
  copy) AENC=(-c:a copy) ;;
  aac)  AENC=(-c:a aac -b:a 192k) ;;
  alac) AENC=(-c:a alac) ;;
  auto)
    AENC=(-c:a copy)
    case "$OUT" in *.mp4|*.m4v)
      case "$ACODEC" in
        pcm_*)
          AENC=(-c:a aac -b:a 192k)
          echo "footage-clean: source audio is ${ACODEC}; encoding aac 192k into mp4 instead of stream-copying (copied PCM becomes 'ipcm'). Use --acodec alac to keep it lossless." ;;
      esac ;;
    esac ;;
  *) echo "footage-clean: --acodec must be auto|copy|aac|alac" >&2; exit 2 ;;
esac

# --single-pass: fuse stage 1 and the final encode. Two reasons it exists: a
# lossless final encode stops being lossless-of-lossy (the intermediate is
# crf 12), and it halves the reads of a 100+ GB capture master. The GPU stages
# need a real file between them, so they rule it out.
ONE_PASS=$SINGLE_PASS
if [ "$ONE_PASS" = 1 ]; then
  if [ "$UPSCALE" != 1 ] || [ "$INTERP" = 1 ]; then
    echo "footage-clean: --single-pass cannot be combined with the GPU stages (video2x reads a file) — drop --single-pass or --upscale/--interp" >&2
    exit 2
  fi
  if [ "$NEED_VS" = 0 ]; then ONE_PASS=0; fi  # no VS stage to fuse: the plain encode is already one pass
fi

echo "  pipeline:"
if [ "$ONE_PASS" = 1 ]; then
  echo "    1. VapourSynth: crop=${CROP:-none} deint=${DEINT_APPLIED}/${FIELD} denoise=${DENOISE} -> straight into the encode (--single-pass)"
else
  [ "$NEED_VS" = 1 ] && echo "    1. VapourSynth: crop=${CROP:-none} deint=${DEINT_APPLIED}/${FIELD} denoise=${DENOISE} -> lossless-ish h264 intermediate"
fi
[ "$UPSCALE" != 1 ] && echo "    2. video2x -p $PROCESSOR -s $UPSCALE --$PROCESSOR-model $MODEL (Vulkan)"
[ "$INTERP" = 1 ] && echo "    3. video2x -p rife -m 2 (rife-v4.6, Vulkan)"
if [ "$LOSSLESS" = 1 ]; then
  ENC_DESC="$CODEC LOSSLESS (qp 0, profile $PROF, ${PIXFMT_EFF:-source} kept, colour=$COLOR_DESC)"
else
  ENC_DESC="$CODEC crf/qp=$CRF preset=$PRESET colour=$COLOR_DESC"
fi
echo "    4. encode: $ENC_DESC ${VF:+vf=$VF} + audio=${A_MODE}($ACODEC)$(
  [ "$ONE_PASS" = 1 ] && echo ' [piped from 1]')"
if [ "$TO" != 0 ]; then
  echo "  trim: keeping ${FROM}s..${TO}s; frames after ${TO}s are never read"
  if awk -v t="$TO" -v d="$DUR" 'BEGIN{exit !(t>d)}'; then
    echo "  note: --to $TO is past the end of this ${DUR}s source"
  fi
fi
if [ "$DRY" = 1 ]; then exit 0; fi
echo

# ---------------------------------------------------------------- temp -----
TMP=$(mktemp -d "${TMPDIR:-/tmp}/footage.XXXXXX")
cleanup() {
  if [ "$KEEP_TEMP" = 1 ]; then
    echo "footage-clean: temp kept in $TMP"
  else
    rm -rf "$TMP"
  fi
}
trap cleanup EXIT

CUR="$IN"
AUDIO_SRC="$IN"
# --test (a short sample to check flags on) and --to (trimming the tail off a
# capture) are the same mechanism: cut the source up front with a stream copy,
# so every stage — the audio included — works on the kept range and the master
# is read once rather than twice.
KEEP=0
if [ "$TEST" != 0 ]; then
  KEEP=$TEST
elif [ "$TO" != 0 ]; then
  KEEP=$(awk -v t="$TO" -v f="$FROM" 'BEGIN{printf "%.6f", t-f}')
fi
TSTOP=()
FC_ENDSEC=""
if [ "$KEEP" != 0 ]; then
  # Exception to the up-front cut: a trim from 0 that only the (single)
  # encoder consumes is better expressed as -t ON THE ENCODE. `-ss 0 -c copy`
  # rewrites the whole kept range as a new file — for a 154 GB capture master
  # that is an extra read AND write of the largest stage, dumped into $TMP,
  # which lives on tmpfs unless TMPDIR says otherwise.
  if [ "$FROM" = 0 ] && [ "$ONE_PASS" = 1 ]; then
    # No intermediate file: -t caps the ENCODE (and the audio with it), and
    # FC_ENDSEC tells clean.vsh to trim the SOURCE clip itself. That second
    # half matters: the deinterlacing chain leans on neighbouring frames, so
    # with only -t its last output frame blends a field of the discarded tail
    # — a blue flash where the tape went to slate (measured: the 150th frame
    # of a 6 s trim from an 8 s master combed in the 7th second's black).
    echo "==> end trim: encode stops at ${KEEP}s (source trimmed in vspipe; no intermediate cut)"
    TSTOP=(-t "$KEEP")
    FC_ENDSEC=$KEEP
  else
    if [ "$TO" != 0 ] && [ "$ONE_PASS" = 0 ]; then
      echo "footage-clean: note: --to without --single-pass stream-copies the kept $(du -h "$IN" | cut -f1)-ish file into $TMP — point TMPDIR at a filesystem with room"
    fi
    echo "==> cutting $(if [ "$FROM" != 0 ]; then printf 'from %ss, ' "$FROM"; fi)${KEEP}s (start snaps to the previous keyframe)"
    $FFMPEG -hide_banner -loglevel error -y -ss "$FROM" -i "$IN" -t "$KEEP" \
      -c copy "$TMP/sample.mkv"
    CUR="$TMP/sample.mkv"
    AUDIO_SRC="$TMP/sample.mkv"
  fi
fi

stage() { # stage label cmd...
  local t0 t1 rc
  t0=$(date +%s)
  echo "==> $1"
  shift
  "$@"
  rc=$?
  t1=$(date +%s)
  if [ "$rc" = 0 ]; then
    echo "    ok ($((t1 - t0))s)"
  else
    echo "    FAILED rc=$rc ($((t1 - t0))s)" >&2
  fi
  return "$rc"
}

# ---------------------------------------------------------------- stage 1 --
if [ "$NEED_VS" = 1 ]; then
  export FC_SRC=$CUR FC_DEINT=$DEINT_APPLIED FC_FIELD=$FIELD \
         FC_DENOISE=$DENOISE FC_CROP=$CROP FC_CHROMA_BLUR=1 FC_ENDSEC=$FC_ENDSEC \
         FC_ME_SEARCH=$ME_SEARCH FC_ME_SEARCHPARAM=$ME_SEARCHPARAM \
         FC_ME_RANGE=$ME_RANGE FC_ME_DIVIDE=$ME_DIVIDE FC_ME_BLEND=$ME_BLEND \
         FC_ME_RBLK=$ME_RBLK FC_DEINT_DEGRAIN=$DEINT_DEGRAIN \
         FC_OSD_RECT=$OSD_RECT FC_OSD_FEATHER=$OSD_FEATHER
  VSCMD="$VSPIPE -r $THREADS -c y4m -p '$CLEANVSH' - 2>'$TMP/vs.log'"
  if [ "$ONE_PASS" = 1 ]; then
    # No crf 12 intermediate: pipe the cleaned frames straight into the encode
    # that is actually kept. That is what makes a lossless final encode
    # lossless, and on a 100+ GB capture master it halves the reading.
    # VSCMD is executed by `bash -c`, so every flag has to survive two rounds
    # of parsing — hence %q. Note `printf '%q ' "" ` is *not* a no-op: with an
    # empty array it prints '' and ffmpeg then receives an empty output
    # filename, so quoting goes through q(), which prints nothing for no args.
    q() { if [ "$#" -gt 0 ]; then printf '%q ' "$@"; fi; }
    QENC=$(q "${ENC[@]}")
    QCOL=$(q ${COLOR[@]+"${COLOR[@]}"})
    QVF=$(q ${VFARGS[@]+"${VFARGS[@]}"})
    QAENC=$(q "${AENC[@]}")
    QSTOP=$(q "${TSTOP[@]+"${TSTOP[@]}"}")
    VSCMD="$VSCMD | $FFMPEG -hide_banner -loglevel error -stats -y -i - -i '$AUDIO_SRC'"
    VSCMD="$VSCMD -map 0:v:0 -map 1:a:0? ${QCOL}${QENC} ${QVF}${QAENC} ${QSTOP}-movflags +faststart '$OUT'"
    STAGE_LABEL="VapourSynth clean + ${CODEC} encode (single pass$(
      if [ "$LOSSLESS" = 1 ]; then printf ', lossless qp 0'; fi))"
  else
    VSCMD="$VSCMD | $FFMPEG -hide_banner -loglevel error -y -i -"
    VSCMD="$VSCMD -c:v libx264 -preset fast -crf 12 -an '$TMP/stage1.mkv'"
    STAGE_LABEL="VapourSynth clean (deint=${DEINT_APPLIED} denoise=${DENOISE} crop=${CROP:-none})"
  fi
  # A -t trim can finish the encoder a hair before vspipe has pushed its last
  # frame; the writer then dies of SIGPIPE (141) with a complete file behind
  # it. Expected for one-pass — tolerated only when $OUT actually exists.
  RUNTAIL=""
  if [ "$ONE_PASS" = 1 ]; then
    RUNTAIL="; rc=\$?; if [ \$rc = 141 ] && [ -s '$OUT' ]; then rc=0; fi; exit \$rc"
  fi
  if stage "$STAGE_LABEL" bash -o pipefail -c "$VSCMD$RUNTAIL"; then
    if [ "$ONE_PASS" = 1 ]; then CUR="$OUT"; else CUR="$TMP/stage1.mkv"; fi
  else
    echo "--- vspipe stderr (tail):" >&2
    tail -40 "$TMP/vs.log" >&2 || true
    exit 1
  fi
fi

# ---------------------------------------------------------------- stage 2 --
if [ "$UPSCALE" != 1 ]; then
  D=()
  [ -n "$GPUDEV" ] && D=(-d "$GPUDEV")
  stage "${PROCESSOR} x${UPSCALE} (${MODEL})" \
    $VIDEO2X -i "$CUR" -o "$TMP/stage2.mp4" -p "$PROCESSOR" -s "$UPSCALE" \
      --"$PROCESSOR"-model "$MODEL" ${D[@]+"${D[@]}"} -e crf=12 -e preset=fast
  CUR="$TMP/stage2.mp4"
fi

# ---------------------------------------------------------------- stage 3 --
if [ "$INTERP" = 1 ]; then
  D=()
  [ -n "$GPUDEV" ] && D=(-d "$GPUDEV")
  stage "RIFE 2x interpolation" \
    $VIDEO2X -i "$CUR" -o "$TMP/stage3.mp4" -p rife -m 2 \
      --rife-model rife-v4.6 ${D[@]+"${D[@]}"} -e crf=12 -e preset=fast
  CUR="$TMP/stage3.mp4"
fi

# ---------------------------------------------------------------- stage 4 --
if [ "$ONE_PASS" = 1 ]; then
  echo "==> final encode was folded into stage 1 (--single-pass)"
else
  stage "final encode ${CODEC}" \
    $FFMPEG -hide_banner -loglevel error -stats -y -i "$CUR" -i "$AUDIO_SRC" \
      -map 0:v:0 -map 1:a:0? ${COLOR[@]+"${COLOR[@]}"} "${ENC[@]}" ${VFARGS[@]+"${VFARGS[@]}"} \
      "${AENC[@]}" -movflags +faststart "$OUT"
fi

echo "==> wrote $OUT ($(du -h "$OUT" | cut -f1), source was $(du -h "$IN" | cut -f1))"
