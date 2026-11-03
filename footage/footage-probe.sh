#!/usr/bin/env bash
# footage-probe — tell me what this footage is and what to do with it.
#
# Decodes nothing beyond a 10 s idet sample: container/stream facts,
# interlacing detection, color-tag sanity, and a suggested footage-clean
# command line. All paths baked in by kit.nix.

set -euo pipefail

FFMPEG=@ffmpeg@
FFPROBE=@ffprobe@
PY=@python3@
export FC_FFPROBE=$FFPROBE

[ $# -ge 1 ] || { echo "usage: footage-probe FILE" >&2; exit 2; }
IN=$1
[ -f "$IN" ] || { echo "footage-probe: no such file: $IN" >&2; exit 1; }

# A headerless raw stream (.uyvy/.yuv from a re-direct, or a raw BT.656 dump
# from pctv_probe) has no container, so ffprobe has nothing to read. Tell the
# user how to wrap it instead of failing with a traceback.
if ! $FFPROBE -v error -show_entries stream=codec_type -of csv=p=0 "$IN" \
     >/dev/null 2>&1; then
  case "${IN##*.}" in
    uyvy|yuv|yuv422|raw|bin)
      echo "$IN: no container — this is a headerless raw stream, ffprobe cannot read it."
      echo "Wrap it losslessly into a master first (the PCTV monitor's rawvideo is"
      echo "uyvy422 720x576@25i TFF; for another layout adjust -pix_fmt/-s/-r):"
      echo
      echo "  ffmpeg -f rawvideo -pix_fmt uyvy422 -s 720x576 -r 25 -field_order tt \\"
      echo "    -i '$IN' -c:v ffv1 -g 1 -an '${IN%.*}.mkv'"
      echo
      echo "(A raw *BT.656* dump from pctv_probe is NOT that — it carries EAV/SAV"
      echo " sync words and needs the monitor's deframer first; it is a diagnostic"
      echo " format, never a pipeline input.)"
      exit 1 ;;
  esac
fi

IFS=$'\t' read -r WIDTH HEIGHT FPS FRATE FIELD_ORDER CSPACE CMATRIX PRIM TRC \
    PIXFMT BITRATE DUR CODEC < <($PY - "$IN" <<'PYEOF'
import json, os, subprocess, sys
data = json.loads(subprocess.check_output([
    os.environ["FC_FFPROBE"], "-v", "error", "-select_streams", "v:0",
    "-show_entries",
    "stream=width,height,r_frame_rate,field_order,pix_fmt,color_space,"
    "color_matrix,color_primaries,color_transfer,bit_rate,codec_name",
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
    float(fmt.get("duration") or 0), s["codec_name"],
))))
PYEOF
)

echo "$IN"
echo "  stream:   $CODEC ${WIDTH}x${HEIGHT} @ ${FRATE} fps, ${PIXFMT}, ${DUR}s, $(( BITRATE / 1000 )) kbps"

# A lossless capture master (pctv-linux --master ffv1|utvideo|uyvy, or any
# other intra-only lossless codec): every sample is exact, so the
# bits-per-pixel quality heuristic is meaningless — and its field-order tag is
# the capture's own declaration, worth more than idet's vote.
MASTER=0
case "$CODEC" in
  ffv1|ffvhuff|huffyuv|utvideo|rawvideo|qtrle) MASTER=1 ;;
esac

if [ "$MASTER" = 1 ]; then
  echo "  bits/px:  n/a — lossless capture master; the pixels ARE the source"
else
  BPP=$(awk "BEGIN{printf \"%.3f\", $BITRATE / ($WIDTH * $HEIGHT * ($FPS>0?$FPS:1))}")
  echo "  bits/px:  $BPP   (0.02+ = fine, 0.01-0.02 = lossy, <0.01 = heavy compression)"
fi

CASE=ok
case "$FIELD_ORDER" in
  tt|bt|tb|bb)
    case "$FIELD_ORDER" in t*) PARM="top field coded first (TFF)";; *) PARM="bottom field coded first (BFF)";; esac
    echo "  fields:   container says '${FIELD_ORDER}' -> INTERLACED, $PARM"
    CASE=interlaced
    if [ "$MASTER" = 1 ]; then
      # What the decoded frames themselves claim (counted, not sampled):
      # ffv1/rawvideo carry per-frame flags; utvideo writes none at all, and
      # only the container tag remembers — which is why masters land here and
      # not in idet's coin-toss (docs/pctv-analog-capture.md §10.3).
      flags=$($FFPROBE -v error -select_streams v:0 -read_intervals "%+2" \
                -show_entries frame=interlaced_frame,top_field_first -of csv=p=0 "$IN" \
                2>/dev/null | sort | uniq -c | paste -sd'  ' -)
      echo "  frame flags: ${flags:-none readable}  (frames: interlaced_frame,top_field_first)"
      case "$CODEC" in
        utvideo)
          echo "            utvideo stores no frame flags — players see 25p unless told;"
          echo "            footage-clean trusts the container tag (top-field-first)." ;;
      esac
    fi
    ;;
  *)
    t0=$(awk "BEGIN{if ($DUR > 40) printf \"%.0f\", $DUR / 4; else print 0}")
    idet_line=$($FFMPEG -hide_banner -v info -ss "$t0" -t 10 -i "$IN" -an \
                  -vf idet -f null - 2>&1 | grep -E 'Multi frame detection' | tail -1 || true)
    read -r T B P < <($PY - <<PYEOF
import re
line = """$idet_line"""
def n(pat):
    m = re.search(pat, line)
    return int(m.group(1)) if m else 0
print(n(r"TFF:\s*(\d+)"), n(r"BFF:\s*(\d+)"), n(r"Progressive:\s*(\d+)"))
PYEOF
)
    inter=$((T + B))
    if [ "$inter" -ge 3 ] && [ "$inter" -gt "$(( (inter + P) / 20 ))" ]; then
      echo "  fields:   idet TFF=$T BFF=$B progressive=$P -> INTERLACED (sampled at ${t0}s)"
      CASE=interlaced
    else
      echo "  fields:   idet TFF=$T BFF=$B progressive=$P -> progressive (sampled at ${t0}s)"
    fi
    ;;
esac

echo "  color:    space=$CSPACE matrix=$CMATRIX primaries=$PRIM transfer=$TRC"
if [ "$CMATRIX" = bt2020c ]; then
  echo "  WARNING:  matrix=bt2020c (constant luminance). Practically every device"
  echo "            writing that is mislabelling bt709/bt2020nc content. Raw"
  echo "            swscale/zimg conversions fail on it; re-tag or use a pipeline"
  echo "            that overrides the matrix."
  CASE="colormislabel ${CASE}"
fi
if [ "$PRIM" = bt2020 ] && [ "$TRC" = unknown ] && [ "$CSPACE" != bt2020nc ]; then
  echo "  note:     bt2020 primaries with unknown transfer on non-HDR content —"
  echo "            tags are probably meaningless; bt709 is a safe restamp."
fi

echo
echo "suggested:"
if [ "$CASE" = interlaced ]; then
  echo "  footage-clean --test 12 --deint qtgmc --denoise light '$IN'"
  if [ "$MASTER" = 1 ] && [ "$WIDTH" = 720 ] && [ "$HEIGHT" = 576 ]; then
    echo "  # PCTV master (720x576): pillar bars + head-switch band + tape colour, per"
    echo "  # the verified recipe — deint auto now trusts this master's field tag:"
    echo "  footage-clean --test 12 --crop 700x556+10+2 --denoise light --grade '$IN'"
  fi
else
  echo "  footage-clean --test 12 --denoise standard '$IN'   # progressive; no deint"
fi
echo "  footage-clean --denoise standard --deband '$IN'      # banded skies?"
echo "  footage-clean --denoise none --upscale 2 '$IN'       # GPU RealESRGAN upscale"
echo "  (footage-clean --help for every knob; README in share/footage/)"
