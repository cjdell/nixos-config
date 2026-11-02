#!/usr/bin/env bash
# footage-clean — one-command video cleanup pipeline.
#
#   probe (interlacing / bad color tags / GPU lease)
#     -> VapourSynth: crop, deinterlace (znedi3/eedi3/QTGMC-style), MDegrain
#     -> optional GPU stages: RealESRGAN upscale, RIFE interpolation
#        (video2x on Vulkan)
#     -> FFmpeg encode (libx265 default; SVT-AV1 / x264 / VAAPI H.265 also
#        available; audio stream-copied).
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
  --codec C           x265|x264|av1|gpu-h265|gpu-h264                (default x265)
  --crf N             quality for CPU codecs / -global_quality for VAAPI
                      (default 20; lower = better)
  --preset P          x265/x264 speed preset (default medium)
  --vaapi-dev PATH    /dev/dri/renderD12x for --codec gpu-* (default renderD128)
  --deband            ffmpeg deband pass (banded skies/gradients)
  --grade             analog colour refresh (eq: saturation 1.18, contrast 1.04)
  --sharpen A         mild unsharp after clean, e.g. 0.4 (default off)
  --test N            process only N seconds (from --from) — test first!
  --from SEC          start offset for --test (default 0)
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
CRF=20
PRESET=medium
VAAPI_DEV=/dev/dri/renderD128
DEBAND=0
GRADE=0
SHARPEN=""
TEST=0
FROM=0
THREADS=""
SOURCE_COLOR=0
KEEP_TEMP=0
DRY=0

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
    --crf) CRF=$2; shift 2 ;;
    --preset) PRESET=$2; shift 2 ;;
    --vaapi-dev) VAAPI_DEV=$2; shift 2 ;;
    --deband) DEBAND=1; shift ;;
    --grade) GRADE=1; shift ;;
    --sharpen) SHARPEN=$2; shift 2 ;;
    --test) TEST=$2; shift 2 ;;
    --from) FROM=$2; shift 2 ;;
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

# ---------------------------------------------------------------- probe ----
IFS=$'\t' read -r WIDTH HEIGHT FPS FRATE FIELD_ORDER CSPACE CMATRIX PRIM TRC \
    PIXFMT BITRATE DUR < <($PY - "$IN" <<'PYEOF'
import json, os, subprocess, sys
data = json.loads(subprocess.check_output([
    os.environ["FC_FFPROBE"], "-v", "error", "-select_streams", "v:0",
    "-show_entries",
    "stream=width,height,r_frame_rate,field_order,pix_fmt,color_space,"
    "color_matrix,color_primaries,color_transfer,bit_rate",
    "-show_entries", "format=duration", "-of", "json", sys.argv[1],
]))
s = data["streams"][0]
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
    float(fmt.get("duration") or 0),
))))
PYEOF
)

DEINT_APPLIED=off
DETECT_NOTE="not checked"
if [ "$DEINT" = auto ]; then
  if [ "$FIELD_ORDER" = tt ] || [ "$FIELD_ORDER" = bt ]; then
    DEINT_APPLIED=qtgmc
    [ "$FIELD" = auto ] && FIELD=$([ "$FIELD_ORDER" = tt ] && echo tff || echo bff)
    DETECT_NOTE="container flags field_order=${FIELD_ORDER} -> interlaced"
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

echo "  pipeline:"
[ "$NEED_VS" = 1 ] && echo "    1. VapourSynth: crop=${CROP:-none} deint=${DEINT_APPLIED}/${FIELD} denoise=${DENOISE} -> lossless-ish h264 intermediate"
[ "$UPSCALE" != 1 ] && echo "    2. video2x -p $PROCESSOR -s $UPSCALE --$PROCESSOR-model $MODEL (Vulkan)"
[ "$INTERP" = 1 ] && echo "    3. video2x -p rife -m 2 (rife-v4.6, Vulkan)"
echo "    4. encode: $CODEC crf/qp=$CRF preset=$PRESET ${VF:+vf=$VF} + audio copy + bt709 tags"
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
if [ "$TEST" != 0 ]; then
  echo "==> sampling ${TEST}s from ${FROM}s"
  $FFMPEG -hide_banner -loglevel error -y -ss "$FROM" -i "$IN" -t "$TEST" \
    -c copy "$TMP/sample.mkv"
  CUR="$TMP/sample.mkv"
  AUDIO_SRC="$TMP/sample.mkv"
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
         FC_DENOISE=$DENOISE FC_CROP=$CROP FC_CHROMA_BLUR=1
  VSCMD="$VSPIPE -r $THREADS -c y4m -p '$CLEANVSH' - 2>'$TMP/vs.log'"
  VSCMD="$VSCMD | $FFMPEG -hide_banner -loglevel error -y -i -"
  VSCMD="$VSCMD -c:v libx264 -preset fast -crf 12 -an '$TMP/stage1.mkv'"
  if stage "VapourSynth clean (deint=${DEINT_APPLIED} denoise=${DENOISE} crop=${CROP:-none})" \
       bash -o pipefail -c "$VSCMD"; then
    CUR="$TMP/stage1.mkv"
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
COLOR=()
[ "$SOURCE_COLOR" = 0 ] && COLOR=(-colorspace bt709 -color_primaries bt709 -color_trc bt709)
VFARGS=()
case "$CODEC" in
  x265) ENC=(-c:v libx265 -preset "$PRESET" -crf "$CRF"
             -x265-params "log-level=none" -tag:v hvc1) ;;
  x264) ENC=(-c:v libx264 -preset "$PRESET" -crf "$CRF" -profile:v high) ;;
  av1)  ENC=(-c:v libsvtav1 -crf "$CRF" -preset 8 -svtav1-params "lp=$THREADS") ;;
  gpu-h265)
    ENC=(-init_hw_device vaapi=va:"$VAAPI_DEV" -filter_hw_device va
         -c:v hevc_vaapi -rc_mode CQP -global_quality "$CRF" -tag:v hvc1)
    VF="${VF:+$VF,}format=nv12,hwupload" ;;
  gpu-h264)
    ENC=(-init_hw_device vaapi=va:"$VAAPI_DEV" -filter_hw_device va
         -c:v h264_vaapi -rc_mode CQP -global_quality "$CRF")
    VF="${VF:+$VF,}format=nv12,hwupload" ;;
  *) echo "footage-clean: unknown codec $CODEC" >&2; exit 2 ;;
esac
[ -n "$VF" ] && VFARGS=(-vf "$VF")

stage "final encode ${CODEC}" \
  $FFMPEG -hide_banner -loglevel error -stats -y -i "$CUR" -i "$AUDIO_SRC" \
    -map 0:v:0 -map 1:a:0? ${COLOR[@]+"${COLOR[@]}"} "${ENC[@]}" ${VFARGS[@]+"${VFARGS[@]}"} \
    -c:a copy -movflags +faststart "$OUT"

echo "==> wrote $OUT ($(du -h "$OUT" | cut -f1), source was $(du -h "$IN" | cut -f1))"
