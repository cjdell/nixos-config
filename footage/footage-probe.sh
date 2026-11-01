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

BPP=$(awk "BEGIN{printf \"%.3f\", $BITRATE / ($WIDTH * $HEIGHT * ($FPS>0?$FPS:1))}")
echo "  bits/px:  $BPP   (0.02+ = fine, 0.01-0.02 = lossy, <0.01 = heavy compression)"

CASE=ok
case "$FIELD_ORDER" in
  tt|bt|tb|bb)
    echo "  fields:   container says '${FIELD_ORDER}' -> INTERLACED"
    CASE=interlaced
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
else
  echo "  footage-clean --test 12 --denoise standard '$IN'   # progressive; no deint"
fi
echo "  footage-clean --denoise standard --deband '$IN'      # banded skies?"
echo "  footage-clean --denoise none --upscale 2 '$IN'       # GPU RealESRGAN upscale"
echo "  (footage-clean --help for every knob; README in share/footage/)"
