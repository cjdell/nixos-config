#!/usr/bin/env bash
# queue-selftest.sh - prove that a stalled sink costs a capture nothing, or say
# exactly what it cost.  The companion to capture-selftest.sh: that one injects
# USB/field-level damage, this one injects SINK damage (ffmpeg frozen with
# SIGSTOP mid-capture) and checks the two things §14.2b promises:
#
#   1. a freeze shorter than the queue is absorbed with zero loss;
#   2. a freeze longer than the queue ENDS the capture (SINK STALLED) and every
#      picture written is in the file - a short complete file, never a long
#      holey one.
#
#   3. since 2026-11-04: a freeze LONGER than the RAM queue is absorbed too, by
#      spilling the backlog (pictures + their sound) to a scratch file on local
#      disk - SINK STALLED must NOT appear, the take stays whole and PTS stays
#      contiguous (case survive-12s-freeze);
#   4. a spill that runs out of scratch space (PCTV_SPILL_MB cap) ends the
#      capture the way §14.2b always did - after SPILL FAILED, with everything
#      already recorded still complete on disk (case spill-cap-64mb);
#   5. PCTV_SPILL_MB=0 restores the pre-spill behaviour exactly: the full queue
#      stops the take (case spill-off-12s-freeze).
#
# And in every case it checks the always-on log the take was written to
# (PCTV_LOG): every line - monitor, probe and ffmpeg alike - carries a
# microsecond wall-clock stamp, and the once-a-second HB line's counters add
# up to the take it was taken during.
#
# It runs against real tape pixels, not synthetic ones: replayprobe.c replays a
# UYVY file as real-time BT.656, so nothing about a deck or the card can excuse a
# loss.  Provide one with REPLAY_UYVY (any 720x576 PAL UYVY; 30 s is plenty), or
# point PCTV_PROBE at a real pctv_probe to test the card instead.
#
#   ./pctv-linux/queue-selftest.sh [source.uyvy]
#
# The spill cases write through PCTV_SPILL_DIR (default below - keep it on REAL
# local disk to test what the capture host actually does, not tmpfs).
#
# History: on 2026-11-02 a 3 h tape came off with `skip 59688` (22 % of its
# pictures evicted to keep a stalled encoder in step) and the monitor then hung
# on quit behind the probe's writer.  Both are fixed; this is what stops them
# coming back.
set -uo pipefail
cd "$(dirname "$0")/.."
HERE=$PWD
PROBE=${PCTV_PROBE:-$HERE/pctv-linux/replayprobe}
UYVY=${1:-${REPLAY_UYVY:-$HOME/bench/clip30.uyvy}}
OUT=${OUT:-/tmp/pctv-queue-selftest}
SECS=${SECS:-20}
FFMPEG=${PCTV_FFMPEG:-$(command -v ffmpeg)}
[ -x "$PROBE" ] || PROBE="$HERE/pctv-linux/replayprobe"
[ -x "$FFMPEG" ] || { echo "ffmpeg not found" >&2; exit 1; }
if [ ! -f "$UYVY" ]; then
  echo "no UYVY source at $UYVY" >&2
  echo "  make one from any capture: ffmpeg -i in.mpg -t 30 -f rawvideo -pix_fmt uyvy422 clip30.uyvy" >&2
  exit 1
fi
mkdir -p "$OUT"; rm -f "$OUT"/*.mkv
SPILL_DIR=${PCTV_SPILL_DIR:-/var/tmp/pctv-queue-selftest-spill}
mkdir -p "$SPILL_DIR"

export PCTV_PROBE="$PROBE" PCTV_NO_SUDO=1 REPLAY_UYVY="$UYVY" REPLAY_SECS=3600
export PCTV_FFMPEG="$FFMPEG" PCTV_LOG=0 SDL_VIDEODRIVER=dummy PCTV_VERBOSE=1

fail=0
# Is the process actually with us?  `kill -0` answers TRUE for a ZOMBIE (a child
# that has exited but that this shell has not reaped yet), and that made the
# "did it ignore SIGTERM?" check report a quit lockup on a run that had already
# finished cleanly.  Ask for a state that is not Z.
alive() { local s; s=$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')
         [ -n "$s" ] && [ "${s#Z}" = "$s" ]; }
# $1 = label, $2 = seconds to freeze ffmpeg (0 = don't freeze), $3 = expect
# "absorbed" (no loss), "stopped" (capture ended itself, file still complete),
# "spill" (the backlog overflowed to the scratch file and came back: no SINK
# STALLED, no loss, a "spill done" line), "spillcap" (the scratch file hit its
# cap: SPILL FAILED + SINK STALLED, file still complete), or
# "quit" (SIGTERM arrives WHILE the sink is frozen and must still come back at once)
# $4 = extra environment for the monitor (e.g. PCTV_SPILL_MB=64)
run() {
  local label=$1 freeze=$2 expect=$3 extraenv=${4:-}
  local log="$OUT/$label.log"
  # The monitor's own always-on log (the PCTV_LOG default is a file; here one
  # per case).  Everything the test greps below still comes from $log - the
  # monitor log is checked for ITS promises: every line stamped, and a
  # heartbeat whose frame counts add up to the take.
  local mlog="$OUT/$label.monitor.log"
  pkill -9 -x replayprobe 2>/dev/null; pkill -9 -x ffmpeg 2>/dev/null; sleep 1
  # Start it as OUR child and keep that pid.  `pgrep -x | head -1` picks the
  # OLDEST match, so a leftover monitor from a previous case (or from a failed
  # run) becomes the one we freeze and signal while the capture under test runs
  # unobserved - which is exactly how this script produced a nondeterministic
  # "quit lockup" FAIL.  Same for ffmpeg: it is a child of the monitor, so ask
  # pgrep for that relationship instead of guessing by name.
  rm -f "$mlog"      # the log is opened O_APPEND: a rerun must not see the last one
  env PCTV_SPILL_DIR="$SPILL_DIR" PCTV_LOG="$mlog" ${extraenv:+$extraenv} \
      ./pctv-linux/pctv-monitor --capture --capture-seconds "$SECS" \
      --master uyvy --out-dir "$OUT" >/dev/null 2>"$log" &
  local mp=$!
  local ff="" _i
  for _i in $(seq 1 120); do
    ff=$(pgrep -P "$mp" -x ffmpeg | head -1)
    [ -n "$ff" ] && break
    alive "$mp" || { echo "$label: monitor died at once (see $log)"; fail=1; return; }
    sleep 0.5
  done
  [ -n "$ff" ] || { echo "$label: ffmpeg never appeared (see $log)"; fail=1; kill -9 "$mp" 2>/dev/null; return; }
  if [ "$freeze" -gt 0 ] && [ "$freeze" -le "$SECS" ]; then
    sleep 4; kill -STOP "$ff"; sleep $((freeze / 2))
    if [ "$expect" = quit ]; then
      # The 2026-11-02 lockup, and its 2026-11-02 sequel (a drain that waited out
      # its whole grace period on a window that had stopped responding): press
      # stop while the picture is flowing into a sink that is not reading.
      local t0=$SECONDS; kill -TERM "$mp"
      local g=0; while alive "$mp" && [ $g -lt 25 ]; do sleep 1; g=$((g+1)); done
      if alive "$mp"; then
        echo "$label: FAIL - frozen sink, quit pressed, still alive after 25 s"; fail=1; kill -9 "$mp" 2>/dev/null
      wait "$mp" 2>/dev/null
      else
        echo "$label: exited $((SECONDS - t0)) s after SIGTERM with the sink frozen"
        [ $((SECONDS - t0)) -le 12 ] || { echo "$label: FAIL - quitting took too long"; fail=1; }
      fi
      pkill -9 -x ffmpeg 2>/dev/null; pkill -9 -x replayprobe 2>/dev/null
      local f2; f2=$(ls -t "$OUT"/pctv-cap-*.mkv 2>/dev/null | head -1)
      [ -n "$f2" ] && rm -f "$f2"
      return
    fi
    sleep $((freeze - freeze / 2)); kill -CONT "$ff"
  fi
  # Wait for the capture to end.  Two legitimate shapes: the deadline runs out
  # and the monitor exits, or the capture ends EARLY (SINK STALLED) and the
  # monitor stays in the live view for the operator - so wait on the log, not on
  # the process, and then quit it the way the user would.
  local waited=0
  while alive "$mp" && [ "$waited" -lt 120 ]; do
    grep -qa 'capture stopped' "$log" && break
    sleep 1; waited=$((waited + 1))
  done
  # Quitting with a tape running used to hang the monitor forever (2026-11-02:
  # waitpid behind a probe writer wedged on a full pipe).  It is part of the test.
  local t0=$SECONDS
  kill -TERM "$mp" 2>/dev/null
  while alive "$mp" && [ $((SECONDS - t0)) -lt 15 ]; do sleep 0.5; done
  if alive "$mp"; then
    echo "$label: FAIL - still alive 15 s after SIGTERM: that is the 2026-11-02 quit lockup"
    kill -9 "$mp" 2>/dev/null; fail=1
  else
    printf '%-22s exited %s s after SIGTERM (quit path ok)\n' "" "$((SECONDS - t0))"
  fi
  wait "$mp" 2>/dev/null          # reap it, or the next case sees a zombie
  pkill -9 -x replayprobe 2>/dev/null
  local f; f=$(ls -t "$OUT"/pctv-cap-*.mkv 2>/dev/null | head -1)
  [ -n "$f" ] || { echo "$label: no output file"; fail=1; return; }

  # Contiguous video PTS is the whole claim: 40 ms from the first packet to the
  # last, no repeats, no gaps.  (Do NOT judge by frames-written against the
  # container duration - that follows whichever stream is longer, usually the
  # audio, and reports holes that are not there.)
  local sz bad span
  sz=$(stat -c %s "$f")
  bad=$(ffprobe -v error -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 "$f" \
        | awk 'NR==1{p=$1;next}{d=$1-p; if(d<0)d=-d; if(d>0.0401)b++; p=$1}END{print b+0}')
  span=$(ffprobe -v error -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 "$f" \
        | awk 'NR==1{f=$1}{l=$1}END{printf "%.3f %.0f", l-f, (l-f)/0.04+2}')
  local frames; frames=$(echo "$span" | awk '{print $2}')
  local counters; counters=$(grep -aoE '\[dup [0-9]+, skip [0-9]+, refused [0-9]+.*\]' "$log" | tail -1)
  local stalled; stalled=$(grep -ac 'SINK STALLED' "$log")
  local spilled_n; spilled_n=$(echo "$counters" | sed -n 's/.*spill \([0-9]*\).*/\1/p')
  local spill_act; spill_act=$(grep -ac 'SPILL ACTIVE' "$log")
  local spill_done; spill_done=$(grep -ac 'spill done:' "$log")
  local spill_fail; spill_fail=$(grep -ac 'SPILL FAILED' "$log")

  printf '%-22s %s\n' "$label" "$counters"
  printf '%-22s PTS steps off 40 ms: %s | span %s s (%s pictures) | SINK STALLED: %s | spill: %s active, %s done, %s failed, %s pairs | %s\n' \
         "" "$bad" "$(echo "$span" | cut -d' ' -f1)" "$frames" "$stalled" \
         "$spill_act" "$spill_done" "$spill_fail" "${spilled_n:-?}" "$f"

  # The always-on log: PCTV_LOG=<path> must have produced the file, every one
  # of its lines (the monitor's, the probe's, ffmpeg's - all share fd 2) must
  # carry the [ISO-8601.µs] stamp, and the once-a-second HB line must tell the
  # truth about the take: its per-second `f=` deltas summed are the frames
  # the capture stopped with, and its count is the seconds it ran.
  [ -s "$mlog" ] \
    || { echo "$label: FAIL - PCTV_LOG file missing or empty"; fail=1; }
  # NB: grep -c PRINTS 0 and EXITS 1 on "no lines selected", so no `|| echo`
  # here - that appends a second "0" and the comparison then sees "0\n0".
  local untagged; untagged=$(grep -vcE \
      '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}\] ' \
      "$mlog" 2>/dev/null); untagged=${untagged:-1}
  [ "$untagged" = "0" ] \
    || { echo "$label: FAIL - $untagged monitor-log lines carry no [..µs] stamp"; fail=1; }
  grep -q 'log start: .*wall .*mono ' "$mlog" \
    || { echo "$label: FAIL - no clock anchor line in the monitor log"; fail=1; }
  grep -q 'log end: wall' "$mlog" \
    || { echo "$label: FAIL - log never ended (tee did not drain at exit)"; fail=1; }
  local hb; hb=$(grep -ac 'monitor: HB t=' "$mlog")
  [ "${hb:-0}" -ge 10 ] && [ "$hb" -le $((SECS + 8)) ] \
    || { echo "$label: FAIL - $hb heartbeat lines in a $SECS s run (want ~1/s)"; fail=1; }
  local hbf; hbf=$(grep -a 'monitor: HB t=' "$mlog" \
                   | sed -n 's/.* f=\([0-9]*\) .*/\1/p' | awk '{s+=$1}END{print s+0}')
  local hberr=$((hbf - frames)); [ $hberr -lt 0 ] && hberr=$((-hberr))
  [ $hberr -le 60 ] \
    || { echo "$label: FAIL - HB frame deltas sum to $hbf, capture committed $frames"; fail=1; }
  printf '%-22s monitor log: %s lines, %s heartbeats, HB f-sum %s vs %s frames\n' \
         "" "$(wc -l < "$mlog")" "$hb" "$hbf" "$frames"

  [ "${bad:-1}" = "0" ] || { echo "$label: FAIL - video PTS is not contiguous"; fail=1; }
  # A stall must not be read as a crystal error: the drift figure used to run away
  # to +42000 ppm (and clamp at +50000) while the sink was behind.
  local runaway; runaway=$(grep -aoE 'ADC runs [+-][0-9]{5,} ppm' "$log" | head -1)
  [ -z "$runaway" ] || { echo "$label: FAIL - drift corrector reported $runaway (a stall is not a crystal)"; fail=1; }
  case $expect in
    absorbed)
      echo "$counters" | grep -qE 'dup 0, skip 0, refused 0' \
        || { echo "$label: FAIL - a freeze shorter than the queue must lose nothing"; fail=1; }
      [ "$stalled" = "0" ] || { echo "$label: FAIL - capture stopped on a short freeze"; fail=1; }
      [ "$spill_act" = "0" ] || { echo "$label: FAIL - a freeze the RAM queue can hold must never touch the scratch file"; fail=1; } ;;
    stopped)
      [ "$stalled" != "0" ] || { echo "$label: FAIL - a freeze longer than the queue must END the capture"; fail=1; }
      [ "$spill_act" = "0" ] || { echo "$label: FAIL - spilled with the spill disabled (PCTV_SPILL_MB=0 must be the pre-spill design)"; fail=1; }
      echo "$log" | grep -q '3/4 full' || true
      [ "${bad:-1}" = "0" ] || fail=1 ;;
    spill)
      # The claim of 2026-11-04: a sink slower than the tape, for longer than
      # the RAM queue, costs the take NOTHING - the pairs waited on the SSD and
      # walked back in order.  Every symptom of the old §14.2b stop must be
      # absent, and the summary must show the pairs actually went to disk.
      [ "$spill_act" != "0" ] || { echo "$label: FAIL - a 12 s freeze overruns the 6 s queue: the spill must have activated"; fail=1; }
      [ "$spill_done" != "0" ] || { echo "$label: FAIL - the backlog never came back (no \"spill done\")"; fail=1; }
      [ "$spill_fail" = "0" ] || { echo "$label: FAIL - the scratch file reported a failure on a healthy disk"; fail=1; }
      [ "$stalled" = "0" ] || { echo "$label: FAIL - capture stopped although the spill had space"; fail=1; }
      echo "$counters" | grep -qE 'dup 0, skip 0, refused 0' \
        || { echo "$label: FAIL - the spill round-trip must lose nothing (dup/skip/refused all 0)"; fail=1; }
      [ "${spilled_n:-0}" -gt 0 ] \
        || { echo "$label: FAIL - the summary reports no spilled pairs for a 12 s freeze"; fail=1; } ;;
    spillcap)
      # Scratch space is the new last resort, so the cap must fail EXACTLY like
      # the full queue used to: shout, stop, and leave a complete file.
      [ "$spill_act" != "0" ] || { echo "$label: FAIL - the spill never activated at this cap"; fail=1; }
      [ "$spill_fail" != "0" ] || { echo "$label: FAIL - a 64 MB cap must run out during a 12 s freeze (no SPILL FAILED)"; fail=1; }
      [ "$stalled" != "0" ] || { echo "$label: FAIL - a failed spill must end the capture (SINK STALLED)"; fail=1; }
      grep -q 'the capture ends exactly where\|nothing after this is' "$log" \
        || { echo "$label: FAIL - the SPILL FAILED line must say where the take ends"; fail=1; } ;;
  esac
  [ -s "$f" ] || { echo "$label: FAIL - empty file"; fail=1; }
  # A rawvideo master is 829440 B a frame: the file must hold what it claims.
  [ "$sz" -gt $(( frames * 829440 * 9 / 10 )) ] \
    || { echo "$label: FAIL - $sz B for $frames pictures"; fail=1; }
  rm -f "$f"
}

echo "== queue-selftest: $(nproc) cores, source $(basename "$UYVY") ($(stat -c %s "$UYVY") B), ${SECS}s captures"
echo "   queue depth: $(grep -aoE 'VQ_SLOTS_SINK [0-9]+' pctv-linux/pctv-monitor.c | head -1), spill dir: $SPILL_DIR"
run absorb-3s-freeze 3 absorbed
run survive-12s-freeze 12 spill
run spill-off-12s-freeze 12 stopped PCTV_SPILL_MB=0
run spill-cap-64mb 12 spillcap PCTV_SPILL_MB=64
run quit-into-frozen-sink 12 quit
echo
[ $fail -eq 0 ] && echo "PASS - a stalled sink costs seconds of tape, never pictures inside a file" \
               || echo "FAIL - see $OUT"
exit $fail
