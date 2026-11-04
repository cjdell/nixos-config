#!/usr/bin/env bash
# pctv-verify-master.sh — verify a pctv-monitor capture master is complete
# and internally consistent, independently of the monitor's own counters.
#
#   scripts/pctv-verify-master.sh pctv-cap-*.mkv [more.mkv ...]
#
# Checks (file-side, on the finalised master):
#   1. container facts   codec/pixfmt/size + field-order tags
#   2. frame flags       every decoded frame says interlaced + TFF/BFF
#   3. no lost frames    full-file frame-hash scan: any *consecutive
#                        identical* frame is a source stall the watchdog
#                        papered over (a repeated picture), and video PTS
#                        must be gap-free CFR at 25 fps
#   4. field order       idet pixel vote over 4 sampled windows
#                        (content agrees with the flags?)
#   5. audio             PTS continuity, peak/clipping (Flat factor),
#                        and the tail vs the video track (the monitor's
#                        end-of-take flush leaves ~0.3 s of audio-only
#                        tail: harmless, but it should be ~constant, not
#                        growing)
# Exit 0 = every check passed on every file.
#
# A take can only be fully verified once pctv-monitor has stopped writing
# it: mid-file the Matroska duration/cues are dummy values and seeking
# reads nothing. Run this after the "capture stopped:" log line.

set -uo pipefail

FF="${FFMPEG:-$(command -v ffmpeg || true)}"
FP="${FFPROBE:-$(command -v ffprobe || true)}"
[ -n "$FF" ] && [ -n "$FP" ] || { echo "need ffmpeg/ffprobe (or FFMPEG=/path)" >&2; exit 2; }
[ $# -ge 1 ] || { echo "usage: $0 FILE.mkv ..." >&2; exit 2; }

FRAMESZ_V=""   # bytes/video frame, from the first file (rawvideo) or n/a
FAIL=0

note() { printf '%s\n' "$*"; }
bad()  { printf '  FAIL: %s\n' "$*"; FAIL=1; }

for F in "$@"; do
  [ -f "$F" ] || { note "$F: no such file"; FAIL=1; continue; }
  note "=== $F"
  S=$($FP -v error -show_entries stream=codec_name,codec_type,width,height,pix_fmt,field_order,sample_rate,channels -of csv=p=0 "$F" 2>/dev/null)
  [ -n "$S" ] || { bad "ffprobe reads nothing — capture still in progress, or corrupt header"; continue; }
  note "$(printf '%s\n' "$S" | sed 's/^/  stream: /')"
  VCODEC=$(printf '%s\n' "$S" | head -1 | cut -d, -f1)

  # 1/2: container + per-frame flags
  FO=$($FP -v error -select_streams v:0 -show_entries stream=field_order -of csv=p=0 "$F")
  case "$FO" in t*|b*) note "  field_order (container): $FO";; *) bad "field_order is '$FO', not interlaced";; esac
  ff=$($FP -v error -select_streams v:0 -read_intervals "%+4" \
        -show_entries frame=interlaced_frame,top_field_first -of csv=p=0 "$F" 2>/dev/null | sort | uniq -c | tr -d '\n')
  note "  frame flags: ${ff:-<unreadable>} (frames: interlaced_frame,top_field_first)"
  case "$VCODEC" in
    ffv1|rawvideo)
      printf '%s' "$ff" | grep -qE '(^|[[:space:]])1,[01]' || \
        bad "$VCODEC master should carry per-frame interlaced flags; it carries none" ;;
    utvideo) note "  (utvideo: no frame flags expected; container tag is the only record)" ;;
  esac

  # 3: full-file duplicate-frame + PTS continuity (video)
  res=$($FF -v error -i "$F" -map 0:v:0 -an -f framehash - 2>/dev/null \
        | awk -F', *' '/^0,/ {
            gsub(/ /,"",$2); gsub(/ /,"",$6)
            if (have && $2 != ppts + 1)                { pg++ }
            if (have && $6 == ph)                      { run++; if (run==1) base=ppts; last=$2 }
            if (run && $6 != ph)                       { printf "DUP %d@%d ", run+1, base; run=0 }
            ph=$6; ppts=$2; have=1; n++ }
          END { if (run) printf "DUP %d@%d(END) ", run+1, base
                printf "frames %d pts_gaps %d\n", n, pg+0 }')
  note "  hash scan: $res"
  case "$res" in *"DUP "*"frames"*) bad "consecutive identical frames above (each is a repeated picture = a source stall; the monitor counts these as 'dup')" ;; esac
  case "$res" in *"pts_gaps [1-9]"*) bad "video PTS is not gap-free CFR (a packet was lost)" ;; esac

  # 4: idet over 4 windows
  DUR=$($FP -v error -show_entries format=duration -of csv=p=0 "$F")
  votes=""
  for w in 0.1 0.3 0.55 0.8; do
    t=$(awk "BEGIN{printf \"%.0f\", $DUR*$w}")
    line=$($FF -hide_banner -v info -ss "$t" -t 10 -i "$F" -an -vf idet -f null - 2>&1 | grep 'Multi frame detection' | tail -1)
    v=$(printf '%s' "$line" | sed 's/^.*Multi frame detection: //')
    votes="${votes}    t=${t}s: ${v:-<no frames>}\n"
    n_tff=$(printf '%s' "$v" | sed -n 's/.*TFF: *\([0-9]*\).*/\1/p'); n_bff=$(printf '%s' "$v" | sed -n 's/.*BFF: *\([0-9]*\).*/\1/p')
    [ "${n_tff:-0}" -eq 0 ] && [ "${n_bff:-0}" -eq 0 ] && bad "idet saw no interlaced frames at t=${t}s"
    case "$FO" in
      t*) [ "${n_bff:-0}" -gt "${n_tff:-0}" ] && bad "idet says BFF-first at t=${t}s but the file claims TFF" ;;
      b*) [ "${n_tff:-0}" -gt "${n_bff:-0}" ] && bad "idet says TFF-first at t=${t}s but the file claims BFF" ;;
    esac
  done
  printf '%b' "$votes" | sed 's/^/  idet:/'

  # 5: audio continuity + level + tail
  apkt=$($FP -v error -select_streams a -show_entries packet=pts_time,duration_time -of csv=p=0 "$F" 2>/dev/null \
        | awk -F, 'NR>1 && $1-prev>0.12 {g++} {prev=$1+0; n++} END {printf "%d %d %.3f\n", n, g+0, prev}')
  npg=$(printf '%s' "$apkt" | awk '{print $2}')
  alat=$(printf '%s' "$apkt" | awk '{print $3}')
  note "  audio: $(printf '%s' "$apkt" | awk '{print $1}') packets, last pts ${alat}s, gaps>120 ms: ${npg}"
  [ "${npg:-0}" -gt 0 ] && bad "audio has ${npg} gaps > 120 ms"
  lvl=$($FF -hide_banner -v info -i "$F" -vn -af volumedetect -f null - 2>&1 \
        | sed -n 's/.*mean_volume: /mean /p;s/.*max_volume: /max /p' | paste -sd' ' -)
  note "  audio level: $lvl"
  printf '%s' "$lvl" | grep -qE 'max (-)?0(\.0+)? dB' && bad "audio peaked at 0 dB (clipping)"
  vl=$($FP -v error -select_streams v:0 -show_entries packet=pts_time,duration_time -of csv=p=0 "$F" 2>/dev/null | tail -1 | awk -F, '{printf "%.3f", $1+$2}')
  # Signed, because the sign is the diagnosis. The monitor cuts audio to match a
  # repeated picture, so a *short* audio track is normal and equals the cut; an
  # audio track LONGER than the picture means sound went missing and the tracks
  # were glued back together with stretch instead of silence - which is what a
  # viewer experiences as the sound lagging, worst at the end of the take
  # (docs/pctv-analog-capture.md §14.2d: pctv-cap-20261104-015210.mkv, +1.183 s).
  sgn=$(awk -v a="$alat" -v v="$vl" 'BEGIN{printf "%+.3f", a-v}')
  ppm=$(awk -v a="$alat" -v v="$vl" 'BEGIN{if(v>0)printf "%+.0f", 1e6*(a-v)/v; else print "n/a"}')
  logline=$(grep -F "capture stopped: $(basename "$F")" "$HOME/.local/state/pctv-monitor.log" 2>/dev/null | tail -1)
  cutb=$(printf '%s' "$logline" | sed -n 's/.* \([0-9]\+\) B cut to match the picture.*/\1/p')
  note "  track tails: video ${vl}s audio ${alat}s (audio ${sgn}s, ${ppm} ppm)"
  [ -n "$logline" ] && note "  monitor said: ${logline#pctv-monitor: }"
  cut=${cutb:-0}
  # audio should end up = video - cut, within the ~0.3 s flush tail plus a frame
  awk -v a="$alat" -v v="$vl" -v cut="$cut" 'BEGIN{exit !((a - v) > 0.5)}' && \
    bad "audio track is ${sgn}s LONGER than the picture: sound was lost and stretched back (14.2d). Expect the sound to lag by about ${sgn}s by the end of this take"
  awk -v a="$alat" -v v="$vl" -v cut="$cut" 'BEGIN{exit !((v - a) > cut/192000.0 + 0.5)}' && \
    bad "audio track ends more than 0.5 s before the picture, beyond its ${cut} B of deliberate cut"

  note "  $(awk "BEGIN{printf \"%.1f s of video, %.1f GB\", $DUR, $(stat -c %s "$F")/1073741824}")"
done

[ "$FAIL" = 0 ] && note "ALL CHECKS PASSED" || note "SOME CHECKS FAILED"
exit "$FAIL"
