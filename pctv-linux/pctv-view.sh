#!/usr/bin/env bash
# pctv-view.sh - watch or record the Pinnacle PCTV 320cx analog inputs.
#
#   ./pctv-view.sh                     live view, Composite 1, PAL
#   ./pctv-view.sh svideo              live view, S-Video
#   ./pctv-view.sh 2 --ntsc            Composite 3, NTSC
#   ./pctv-view.sh --ctl               qv4l2 panel: inputs, standard, picture
#                                      controls, raw frame dumps
#   ./pctv-view.sh --grey              chroma off (saturation=0) - the cheap
#                                      fix for the green cast (FINDINGS 9/12)
#   ./pctv-view.sh --deint             yadif deinterlace in the viewer
#   ./pctv-view.sh --rec clip.mkv      record instead of view; --codec
#                                      libx264|libx265|libsvtav1|mjpeg|ffv1|
#                                      yuv4, --crf, --preset, --secs N
#
# For the full GUI route (live preview + input picker + encoder dropdown) use
# OBS Studio: add a "Video Capture Device" source, pick "Pinnacle PCTV 320cx"
# and the input under Video Settings, then Settings -> Output -> Recording.
#
# One capturer at a time: OBS keeps /dev/video0 open for its whole lifetime
# (so a CLI capture gets EBUSY until OBS quits), and two streaming capturers
# would split the frame queue (~50 fps each instead of 25).
set -u

NODE=""
IN=""
STD="pal"
SAT=""
DEINT=0
MODE="view"
OUT=""
CODEC="libx264"
CRF="23"
PRESET="ultrafast"
SECS=""

die() {
  echo "pctv-view: $*" >&2
  exit 1
}

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    1 | composite1 | comp1 | c1) IN=0 ;;
    2 | composite2 | comp2 | c2) IN=1 ;;
    3 | composite3 | comp3 | c3) IN=2 ;;
    4 | svideo | s-video | sv) IN=3 ;;
    --pal) STD="pal" ;;
    --ntsc) STD="ntsc-m" ;;
    --ctl) MODE="ctl" ;;
    --grey) SAT=0 ;;
    --sat)
      SAT="${2:-}"
      [ -n "$SAT" ] || die "--sat needs a value"
      shift
      ;;
    --deint) DEINT=1 ;;
    --rec)
      MODE="rec"
      OUT="${2:-}"
      [ -n "$OUT" ] || die "--rec needs an output file"
      shift
      ;;
    --codec)
      CODEC="${2:-}"
      [ -n "$CODEC" ] || die "--codec needs a value"
      shift
      ;;
    --crf)
      CRF="${2:-}"
      shift
      ;;
    --preset)
      PRESET="${2:-}"
      shift
      ;;
    --secs)
      SECS="${2:-}"
      shift
      ;;
    -h | --help) usage ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

# The PCTV node is not fixed: the iSight camera owns /dev/video1+2, and the
# order depends on probe timing.
for v in /dev/video*; do
  [ -e "$v" ] || continue
  name=$(v4l2-ctl -d "$v" -D 2>/dev/null | sed -n 's/.*Card type *: *//p')
  case "$name" in *PCTV*) NODE="$v" ;; esac
done
[ -n "$NODE" ] ||
  die "no PCTV video node - is the card seated? (sudo dmesg | grep pctv320cx, ./test-driver.sh)"

echo "device: $NODE"

# Standard first, then input: both are decoder re-inits, and the standard
# decides the line count the deframer expects.
# NB VIDIOC_S_STD currently comes back EINVAL on this driver (the glue's
# pctv_s_std is registered and info.stds = PAL-B|NTSC-M, but the call is
# refused), so the decoder stays on its PAL default.  Tracked in FINDINGS.md.
v4l2-ctl -d "$NODE" --set-standard="$STD" >/dev/null 2>&1 ||
  echo "note: VIDIOC_S_STD($STD) refused (EINVAL) - decoder stays on PAL"
if [ -n "$IN" ]; then
  v4l2-ctl -d "$NODE" --set-input="$IN" || die "set-input $IN failed"
fi
[ -n "$SAT" ] && v4l2-ctl -d "$NODE" -c "saturation=$SAT" >/dev/null 2>&1

v4l2-ctl -d "$NODE" --get-input
v4l2-ctl -d "$NODE" -D | sed -n 's/.*Card type *: */card:     /p'
# Signal state: the tuner's signal column is the CX25843 video-detect bit.
v4l2-ctl -d "$NODE" --get-tuner | grep -i signal | sed 's/^\t*/signal:     /'
v4l2-ctl -d "$NODE" --get-fmt-video | sed -n 's/^\t\(Width\/Height\|Pixel Format\|Field\) */\1/p'

case "$MODE" in
ctl)
  exec qv4l2 -d "$NODE"
  ;;
rec)
  WH=$(v4l2-ctl -d "$NODE" --get-fmt-video | sed -n 's|.*Width/Height *: *\([0-9]*\)/\([0-9]*\).*|\1x\2|p')
  FPS=$(v4l2-ctl -d "$NODE" --get-parm | sed -n 's|.*Frames per second: *\([0-9.]*\).*|\1|p' | cut -d. -f1)
  [ -n "$WH" ] || WH=720x576
  [ -n "$FPS" ] || FPS=25
  enc=(-c:v "$CODEC")
  case "$CODEC" in
    libx264 | libx265 | libsvtav1 | libaom-av1) enc+=(-preset "$PRESET" -crf "$CRF") ;;
    mjpeg) enc+=(-q:v "$CRF") ;;
  esac
  cmd=(ffmpeg -f v4l2 -input_format uyvy422 -video_size "$WH" -framerate "$FPS" -i "$NODE")
  [ -n "$SECS" ] && cmd+=(-t "$SECS")
  cmd+=("${enc[@]}" -an "$OUT")
  echo "record: ${cmd[*]}"
  exec "${cmd[@]}"
  ;;
view)
  [ -x "$(command -v mpv)" ] || die "mpv not installed (environment.systemPackages: mpv)"
  vf=""
  [ "$DEINT" = 1 ] && vf="--vf=yadif=0:-1:0"
  # av://v4l2:<node> is the mpv >=0.35 spelling (the old tv:// options are
  # gone).  --profile=low-latency + --untimed: the driver's buffers carry no
  # usable pts, so mpv must not try to pace them against a container clock.
  # --gpu-api=opengl: there is no Vulkan driver on this box (nv50/nvac on
  # nouveau), and mpv's gpu-next VO wastes a second probing for one.
  exec mpv --force-window --gpu-api=opengl --profile=low-latency --untimed $vf "av://v4l2:$NODE"
  ;;
esac
