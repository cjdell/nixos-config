#!/usr/bin/env bash
# pctv-desync-repair.sh - pull a recording's sound back onto its picture
# without touching one frame of the picture.
#
# For the masters this repo's own capture code made before 2026-11-04 the sound
# lags, and the lag GROWS (docs/pctv-analog-capture.md §14.2d: nearly right at the
# start, over a second late by the end).  That rules out the obvious repairs.  One
# global shift is right at one instant and wrong everywhere else; one global tempo
# change - a global shift's other form - assumes the drift was linear, and it was
# not: it tracked how long the picture queue spent deep, so it wanders, and both
# signs occur from take to take.
#
# What does work is a piecewise tempo correction.  Measure the lag at a handful of
# timestamps, take it as piecewise linear between them, and give each span the
# tempo that loses exactly the drift it contains:
#
#     new[p] = old[p + d(p)]          factor = (L + drift) / L
#
# A 1200 s span shedding 195 ms plays at 1.000163 - 163 ppm, 0.28 cents, the same
# inaudible order of resampling the capture path already does by design (§14.2.2).
# Nothing is cut out of the middle and nothing is spliced, so there are no clicks
# and no lost content: the sound is stretched, it lands exactly on the picture at
# every anchor, and between anchors it is off by less than the anchor spacing
# allows.  Two implementation notes, both learned the hard way here:
#
#   * `atempo` is the wrong tool: it is WSOLA, and at 1.0002 it does arithmetic the
#     signal does not need and can breathe on sustained tones.  Resampling does the
#     job exactly.
#   * `asetrate` takes an *integer* sample rate, so at 48 kHz its tempo granularity
#     is 1/48000 = 20.8 ppm - 25 ms over a 20-minute span, which is most of the
#     error being repaired.  So every span is resampled up to 480 kHz first,
#     reinterpreted there (granularity 1.04 ppm) and resampled back: 0.3 ppm
#     measured, ~0.4 ms over a 1200 s span.
#
# Usage
#   ./pctv-desync-repair.sh --clip   OUT.mp4 T FILE [NUDGE_MS]
#   ./pctv-desync-repair.sh --plan   FILE "P:MS,P:MS,..."
#   ./pctv-desync-repair.sh --audio  OUT.wav FILE "P:MS,..." [--from WAV] [--to S]
#   ./pctv-desync-repair.sh --remux  OUT.mkv FILE "P:MS,..." [--from WAV] [--to S] [--yes]
#
#   --clip   a CLIPLEN-second preview at picture time T (default 12 s) for judging
#            the lag.  NUDGE_MS moves the clip's audio to test a guess: positive
#            moves the sound EARLIER, which is what a late sound needs.  The master
#            seeks instantly (it has cues), so an anchor converges in two or three
#            cuts.  Put the clip on a fast local disk, not on ds-public.
#   --plan   print the spans, the factors and the cost; writes nothing.  Always
#            first: it is where a mis-measured anchor shows up as an absurd ppm.
#   --audio  the corrected audio as one WAV, master untouched.  The cheap path: the
#            master is read once (its PCM is interleaved with the video, so that
#            read is unavoidable) and ~1.4 GB is written - and that WAV is exactly
#            what the footage kit's encode wants as its audio input.
#   --remux  the master rebuilt with corrected audio and the video stream-copied
#            (bit-identical frames), but it reads *and writes* the whole file -
#            152 GB for a 2 h raw master - so prefer --audio and let the transcode
#            you were going to do anyway carry the new audio.  Checks free space,
#            and asks, unless --yes.
#
#   "P:MS,..."  anchors: picture time in seconds : how many ms the sound is BEHIND
#               the picture there (positive = the word arrives after the lips,
#               which is how these masters fail).  Order does not matter.  Before
#               the first anchor the lag is held constant, i.e. the first d0 ms of
#               audio - sound from before the first picture - is dropped, not
#               stretched.
#
#   --from WAV  use this WAV instead of extracting from FILE
#               (make one with: ffmpeg -i FILE -vn -c:a pcm_s16le audio.wav)
#   --to S      force the audio track to exactly S s (default: the master's video
#               duration), padding silence or trimming the tail
#
# Environment: FFMPEG= FFPROBE= to pick binaries, CLIPLEN= for --clip.
set -uo pipefail

FF="${FFMPEG:-$(command -v ffmpeg || true)}"
FP="${FFPROBE:-$(command -v ffprobe || true)}"
[ -n "$FF" ] && [ -n "$FP" ] || { echo "need ffmpeg/ffprobe (or FFMPEG=/path)" >&2; exit 2; }
CLIPLEN=${CLIPLEN:-12}
UP=480000                    # the intermediate rate every span is warped at
MODE="${1:-}"; shift || true
usage() { sed -n '2,60p' "$0"; exit 2; }
[ -n "$MODE" ] || usage
dur_of() {   # a track's duration from the container's own tag: cheap, no demux
  $FP -v error -select_streams "$1" -show_entries stream_tags=DURATION -of csv=p=0 "$2" \
    | awk -F: 'NF==3{printf "%.6f", $1*3600+$2*60+$3} NF==1{printf "%.6f", $1}'
}

# ------------------------------------------------------------- --clip -----
if [ "$MODE" = "--clip" ]; then
  OUT=${1:-} T=${2:-} F=${3:-} NUDGE=${4:-0}
  { [ -n "$OUT" ] && [ -n "$T" ] && [ -f "$F" ]; } || usage
  case $NUDGE in *[!0-9-]*) echo "NUDGE_MS must be a number of ms" >&2; exit 2;; esac
  # A late sound is fixed by moving it earlier: drop the first NUDGE ms of audio
  # and stand silence back in front of it, so the clip keeps its length.  A
  # negative nudge delays it, which is how you prove you overshot.
  if   [ "$NUDGE" -gt 0 ]; then AF="atrim=start=$(awk -v n="$NUDGE" 'BEGIN{printf "%.6f", n/1000}'),asetpts=PTS-STARTPTS,adelay=${NUDGE}|${NUDGE},apad"
  elif [ "$NUDGE" -lt 0 ]; then AF="adelay=$(( -NUDGE ))|$(( -NUDGE ))"
  else AF="anull"; fi
  tmp=$(mktemp /tmp/pctv-clip-XXXXXX.mp4)
  timeout 900 $FF -hide_banner -v error -ss "$T" -t "$CLIPLEN" -i "$F" \
    -vf yadif -af "$AF" -c:v libx264 -preset veryfast -crf 22 -c:a aac -b:a 192k \
    -metadata title="sync check ${T}s nudge ${NUDGE}ms" -y "$tmp" || { echo "clip failed" >&2; exit 1; }
  mv "$tmp" "$OUT"
  note="uncorrected"
  [ "$NUDGE" -gt 0 ] && note="moved earlier by ${NUDGE}ms - if it is now EARLY, the lag here is less than ${NUDGE}ms"
  [ "$NUDGE" -lt 0 ] && note="moved later by $((-NUDGE))ms - if it is still LATE, the lag here is more than $((-NUDGE))ms"
  echo "$OUT  t=${T}s ${CLIPLEN}s  audio ${note}"
  exit 0
fi

# -------------------------------------------------------------- inputs ----
OUT=${1:-}; F=${2:-}; ANCHORS=${3:-}
[ -n "$OUT" ] && [ -f "$F" ] && [ -n "$ANCHORS" ] || { echo "$F/$OUT: need OUT FILE \"anchors\"" >&2; usage; }
# the picture's length: the video track's tag, else the container's own duration
# (a bare WAV given to --from has no video track, and --to then decides)
VDUR=$(dur_of v:0 "$F")
[ -n "$VDUR" ] || VDUR=$($FP -v error -show_entries format=duration -of csv=p=0 "$F" | head -1)
[ -n "$VDUR" ] || { echo "$F: no duration to work from - give --to <seconds>" >&2; exit 1; }
shift 3
FROM="" TO=$VDUR ASK=1
while [ $# -gt 0 ]; do
  case $1 in
    --from) FROM=${2:-}; shift 2;;
    --to)   TO=${2:-};   shift 2;;
    --yes)  ASK=0;       shift;;
    *) echo "unknown option: $1" >&2; usage;;
  esac
done

n=0; declare -a PT PD
for a in $(printf '%s' "$ANCHORS" | tr ',' ' '); do
  p=${a%%:*}; d=${a##*:}
  case $p in ''|*[!0-9.]*) echo "bad anchor '$a' (want picture_seconds:ms)" >&2; exit 2;; esac
  case $d in ''|*[!0-9-]*) echo "bad anchor '$a' (want picture_seconds:ms)" >&2; exit 2;; esac
  PT[$n]=$p; PD[$n]=$d; n=$((n+1))
done
[ "$n" -ge 2 ] || { echo "need at least two anchors, e.g. \"60:0,3600:600,7295:1180\"" >&2; exit 2; }
for i in $(seq 0 $((n-1))); do for j in $(seq 0 $((n-1))); do      # sort by picture time
  awk -v a="${PT[$i]}" -v b="${PT[$j]}" 'BEGIN{exit !(a<b)}' && {
    p=${PT[$i]}; d=${PD[$i]}; PT[$i]=${PT[$j]}; PD[$i]=${PD[$j]}; PT[$j]=$p; PD[$j]=$d; }
done; done

# -------------------------------------------------------------- the plan --
# For a span of picture [p0,p1] the sound that belongs in it is the old audio in
# [p0+d0, p1+d1] - longer than the span by exactly the drift it collected - so it
# plays at (L+drift)/L.  Head: old [d0, p0+d0] at 1.0 (the front d0 ms is sound
# from before the first picture).  Tail: old [p_last+d_last, end] at 1.0.  The
# result is (old audio length - d_last) long, which is the video's length when the
# last anchor is the end-of-take lag.
echo "file     : $F"
echo "video    : ${VDUR} s   (audio forced to ${TO} s)"
echo "anchors  : the sound is behind the picture by"
for i in $(seq 0 $((n-1))); do printf '           picture %-9s %+7s ms\n' "${PT[$i]}" "${PD[$i]}"; done
printf '%-6s %-20s %-18s %-10s %-12s %s\n' span 'picture s' 'audio src s' drift factor ppm
worst=0; declare -a SEG; m=0
add() { SEG[$m]="$1 $2 $3 $4 $5"; m=$((m+1)); }
if awk -v p="${PT[0]}" 'BEGIN{exit !(p>0.001)}'; then
  add 0 "${PT[0]}" "$(awk -v d="${PD[0]}" 'BEGIN{printf "%.6f", d/1000}')" \
        "$(awk -v a="${PT[0]}" -v d="${PD[0]}" 'BEGIN{printf "%.6f", a+d/1000}')" 1.000000000
fi
for i in $(seq 0 $((n-2))); do
  set -- $(awk -v p0="${PT[$i]}" -v p1="${PT[$((i+1))]}" -v d0="${PD[$i]}" -v d1="${PD[$((i+1))]}" '
      BEGIN{ L=p1-p0; dr=(d1-d0)/1000.0
             if (L<=0) { print "0 0 0 0 1.000000000 0"; exit }
             k=(L+dr)/L
             printf "%.6f %.6f %.6f %.6f %.9f %.0f", p0, p1, p0+d0/1000.0, p1+d1/1000.0, k, (k-1)*1e6 }')
  add "$1" "$2" "$3" "$4" "$5"
  [ "$5" != "1.000000000" ] && { awk -v p="$6" -v w="$worst" 'BEGIN{if(p<0)p=-p; exit !(p>w)}' && worst=$6; }
done
add "${PT[$((n-1))]}" "$TO" "$(awk -v p="${PT[$((n-1))]}" -v d="${PD[$((n-1))]}" 'BEGIN{printf "%.6f", p+d/1000.0}')" \
    "" 1.000000000
for s in "${SEG[@]}"; do
  set -- $s
  ppm=$(awk -v k="$5" 'BEGIN{printf "%.0f", (k-1)*1e6}')
  dr="$(awk -v a="$1" -v b="$2" -v k="$5" 'BEGIN{printf "%.0f ms", (a==b)?0:(b-a)*(k-1)}')"
  src="$3"; [ -z "$4" ] && src="$3.." || src="$3-$4"
  printf '%-6s %-20s %-18s %-10s %-12s %s\n' "$ppm" "$1-$2" "$src" "$dr" "$5" "$ppm"
done
awk -v w="$worst" 'BEGIN{exit !(w>3000)}' && {
  echo "  STOP: a span needs ${worst} ppm, past the ~3000 ppm (3.5 cents) that stays"
  echo "  inaudible.  Either two anchors are too close together, or the lag between"
  echo "  them was mis-measured.  Re-measure with --clip before writing anything."
  exit 1; }
echo "cost     : $(awk -v a="${PD[0]}" -v b="${PD[$((n-1))]}" 'BEGIN{printf "%.0f", b-a}') ms of audio time removed in total (the measured drift), spread over the spans above"
echo "           $(awk -v d="${PD[0]}" 'BEGIN{printf "%.0f", d}') ms dropped from the front (sound from before the first picture)"
echo "residual : exact at every anchor; between anchors bounded by how far apart they are"
[ "$MODE" = "--plan" ] && { echo; echo "plan only - nothing written"; exit 0; }

# ------------------------------------------------------------- the work ---
W=$(mktemp -d /tmp/pctv-desync-XXXXXX); trap 'rm -rf "$W"' EXIT
if [ -n "$FROM" ]; then
  [ -f "$FROM" ] || { echo "$FROM: no such file" >&2; exit 1; }
  cp "$FROM" "$W/in.wav"; echo "audio    : $FROM"
else
  echo "audio    : extracting - one full read of the master (the PCM is interleaved"
  echo "           with 152 GB of video, and there is no way to read only the sound)"
  timeout 14400 $FF -hide_banner -v error -i "$F" -vn -c:a pcm_s16le -y "$W/in.wav" \
    || { echo "extraction failed" >&2; exit 1; }
fi
ADUR=$($FP -v error -show_entries format=duration -of csv=p=0 "$W/in.wav")
echo "           ${ADUR} s of PCM"

list="$W/list.txt"; : > "$list"; k=0
for s in "${SEG[@]}"; do
  set -- $s
  st=$3 en=$4 f=$5
  [ -z "$en" ] && en=$ADUR
  d=$(awk -v a="$en" -v b="$st" 'BEGIN{printf "%.6f", a-b}')
  awk -v d="$d" 'BEGIN{exit !(d>0.001)}' || continue
  r=$(awk -v k="$f" 'BEGIN{printf "%d", '"$UP"'*k}')
  # up to ${UP}, reinterpret the sample rate there (1.04 ppm granularity instead of
  # the 20.8 ppm an integer asetrate at 48 kHz allows), back down to 48 kHz
  timeout 3600 $FF -hide_banner -v error -ss "$st" -t "$d" -i "$W/in.wav" \
    -af "aresample=${UP},asetrate=${r},aresample=48000,asetpts=PTS-STARTPTS" \
    -ar 48000 -ac 2 -c:a pcm_s16le -y "$W/seg$k.wav" || { echo "span $k failed" >&2; exit 1; }
  printf "file '%s'\n" "$W/seg$k.wav" >> "$list"; k=$((k+1))
  printf '  span %d: %s s -> %s s\n' "$k" "$d" "$($FP -v error -show_entries format=duration -of csv=p=0 "$W/seg$k.wav")"
done
[ "$k" -gt 0 ] || { echo "nothing to write" >&2; exit 1; }
timeout 900 $FF -hide_banner -v error -f concat -safe 0 -i "$list" -c copy -y "$W/warped.wav" \
  || { echo "concat failed" >&2; exit 1; }
timeout 900 $FF -hide_banner -v error -i "$W/warped.wav" \
  -af "apad,atrim=end=${TO},asetpts=PTS-STARTPTS" -ar 48000 -c:a pcm_s16le -y "$W/fixed.wav" \
  || { echo "length fix failed" >&2; exit 1; }
FDUR=$($FP -v error -show_entries format=duration -of csv=p=0 "$W/fixed.wav")
echo "fixed    : ${FDUR} s of audio against ${TO} s of picture ($(
  awk -v a="$FDUR" -v v="$TO" 'BEGIN{printf "%+.0f ms", (a-v)*1000}'))"

case "$MODE" in
  --audio)
    cp "$W/fixed.wav" "$OUT" && echo "wrote    : $OUT"
    echo "next     : encode with it -  ffmpeg -i $F -i $OUT -map 0:v:0 -map 1:a:0"
    echo "                                -c:v <your encode> -c:a pcm_s16le out.mkv"
    echo "           (that is how the footage kit takes it, and it costs no extra"
    echo "           pass over the master)"
    ;;
  --remux)
    need=$(awk -v v="$VDUR" 'BEGIN{printf "%.0f", v*21.7e6}')
    have=$(df -B1 --output=avail "$(dirname "$OUT")" 2>/dev/null | tail -1 | tr -d ' ')
    echo "remux    : reads the master and writes $OUT (~$((need/1073741824)) GB) -"
    echo "           the frames are stream-copied, so they stay bit-identical"
    [ -n "$have" ] && echo "           $(awk -v h="$have" 'BEGIN{printf "%.0f GB free at the destination", h/1073741824}')"
    if [ "$ASK" = 1 ]; then printf '           proceed? [y/N] '; read -r y; [ "$y" = y ] || { echo "cancelled"; exit 1; }; fi
    timeout 14400 $FF -hide_banner -v error -i "$F" -i "$W/fixed.wav" \
      -map 0:v:0 -map 1:a:0 -c:v copy -c:a pcm_s16le -map_metadata 0 -y "$OUT" \
      || { echo "remux failed" >&2; exit 1; }
    echo "wrote    : $OUT"
    echo "check    : $(basename "$0") --plan is stale now - re-cut an anchor clip"
    echo "           from $OUT and confirm the lag reads 0 at every anchor;"
    echo "           then scripts/pctv-verify-master.sh $OUT"
    ;;
  *) echo "internal: unknown mode $MODE" >&2; exit 2;;
esac
