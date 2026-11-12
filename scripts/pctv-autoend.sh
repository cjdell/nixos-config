#!/run/current-system/sw/bin/env bash
# Stop a running pctv-monitor capture when the tape ends.
#
# SINCE 2026-11-02 THE MONITOR DOES THIS ITSELF, better: it sees the frames, and a
# frozen one is bit-identical, so it closes the file after PCTV_HOLD_SECS (600 s now,
# raised from 120 because a damaged patch of tape is bit-identical too) and opens
# another when the picture moves.  Since 2026-11-03 it also catches the deck's
# no-signal BLUE screen (PCTV_BLUE_SECS, 60 s), which is not bit-identical and which
# this script cannot see at all; since 2026-11-12 that closes the file and keeps
# watching (the next tape reopens recording by itself) instead of quitting.  This
# script is the fallback for an older monitor and for anyone who wants the *process*
# gone rather than idle; PCTV_HOLD_MAX is the knob for the usual case.
#
# Why it works by watching the file: the DVD master is rate-CAPPED (-b:v/-maxrate
# 6000k), so live programme sits at the ceiling - ~776 kB/s measured on
# 2026-11-02 overnight.  When a camcorder reaches the end of a tape it stops and
# holds a still frame (or a blue screen), and a still frame at a fixed quality
# target costs a few percent of that.  So "the file has nearly stopped growing"
# means "the picture has stopped moving", which is the end of the tape.  (If the
# deck instead fills with static, entropy goes UP, not down, and this detector
# cannot see it - that is what PCTV_END_MAX is for.)  It averages a rate over a
# window, so it needs ~9 min of frozen frame and cannot tell a mid-tape blank that
# long from the end; the monitor needs 10 min and does not have to decide.
#
# The capture is never interrupted: this only stat()s the output file, and at the
# end sends SIGTERM to the monitor, which is the same path Ctrl-C takes -
# cap_stop() closes the pipes, ffmpeg flushes and finalises the file, and the
# probe is stopped so the card is released.
#
#   ./scripts/pctv-autoend.sh              # defaults: 10 min of still picture,
#                                          # 4 h hard backstop
#   PCTV_END_CONFIRM=300 ./scripts/pctv-autoend.sh
#   PCTV_END_MAX=5400 ./scripts/pctv-autoend.sh      # stop by 01:30 no matter what
#   ./scripts/pctv-autoend.sh --status     # what it is seeing, then exit
#   ./scripts/pctv-autoend.sh --stop-now   # do the clean stop immediately
set -uo pipefail

CONFIRM=${PCTV_END_CONFIRM:-600}       # s the picture must stay still
THRESH=${PCTV_END_RATE:-150000}        # B/s below which it counts as still
MAX=${PCTV_END_MAX:-14400}            # s hard backstop
INTERVAL=${PCTV_END_INTERVAL:-30}     # s between samples
# A window shorter than ~3 samples measures nothing: the warm-up gate below is
# then satisfied by the first pair, so one stall of one poll ends the capture.
# Refuse the configuration instead of honouring it.
if [ "$PCTV_END_CONFIRM" ] && [ "$PCTV_END_CONFIRM" -lt $(( 3 * INTERVAL )) ]; then
    echo "PCTV_END_CONFIRM=$PCTV_END_CONFIRM is under 3*PCTV_END_INTERVAL ($INTERVAL):" >&2
    echo "the window would be a single sample - raise it or leave it at 600" >&2
    exit 2
fi
LOG=${PCTV_END_LOG:-/tmp/pctv-autoend.log}
VIDEOS=${PCTV_VIDEOS:-$HOME/Videos}

say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG" >&2; }

# The launcher runs the wrapped binary, whose comm is ".pctv-monitor-w", so -x by
# name misses it; match the command line, which ends in the wrapper's path.
mon_pid() { pgrep -f '/pctv-monitor$' 2>/dev/null | grep -vx "$$" | head -1; }

cap_file() {
    local ff
    ff=$(pgrep -f 'ffmpeg.*pctv-cap' | head -1)
    [ -n "$ff" ] || return 1
    tr '\0' ' ' <"/proc/$ff/cmdline" 2>/dev/null | grep -oE "$VIDEOS/pctv-cap-[0-9-]+\.(mpg|mkv)" | tail -1
}

[ -n "${1:-}" ] || set -- ""
case "$1" in
    --status)
        p=$(mon_pid); f=$(cap_file || true)
        echo "monitor: ${p:-not running}   capture: ${f:-none}"
        [ -n "$f" ] && ls -l --time-style=+%H:%M:%S "$f"
        exit 0 ;;
    --stop-now) ;;
    "") ;;
    *) echo "usage: $0 [--status|--stop-now] (config via PCTV_END_* env)" >&2; exit 2 ;;
esac

MON=$(mon_pid)
[ -n "$MON" ] || { echo "no pctv-monitor running - nothing to stop" >&2; exit 1; }
FILE=$(cap_file || true)
[ -n "$FILE" ] || { echo "monitor $MON is up but no capture is running" >&2; exit 1; }

if [ "$1" != "--stop-now" ]; then
    say "watching $FILE (monitor $MON): stop after ${CONFIRM}s under ${THRESH}B/s, hard cap ${MAX}s"
    start=$(date +%s)
    declare -a TS=() SZ=()
    while :; do
        kill -0 "$MON" 2>/dev/null || { say "monitor exited by itself; nothing to do"; exit 0; }
        ff=$(pgrep -f 'ffmpeg.*pctv-cap' | head -1)
        [ -n "$ff" ] || { say "encoder gone - capture already ended"; exit 0; }
        sz=$(stat -c %s "$FILE" 2>/dev/null || echo 0)
        now=$(date +%s)
        TS+=("$now"); SZ+=("$sz")
        # Drop samples older than the confirmation window. Recompute the element
        # count AFTER this: reading it before and indexing with it afterwards ran
        # one past the end, and under `set -u` that killed the watchdog 11 min
        # into its shift on 2026-11-02 and the capture ran 9h past the tape.
        while [ "${#TS[@]}" -gt $(( CONFIRM / INTERVAL + 2 )) ]; do
            unset 'TS[0]' 'SZ[0]'
            TS=(${TS[@]+"${TS[@]}"}); SZ=(${SZ[@]+"${SZ[@]}"})
        done
        # rate across the window we have so far
        last=$(( ${#TS[@]} - 1 ))
        el=$(( ${TS[$last]} - ${TS[0]} )); d=$(( ${SZ[$last]} - ${SZ[0]} ))
        rate=0; [ "$el" -gt 0 ] && rate=$(( d / el ))
        if [ "$el" -ge $(( CONFIRM - INTERVAL )) ]; then
            say "window ${el}s rate ${rate} B/s size $(( sz / 1048576 )) MB"
            if [ "$rate" -lt "$THRESH" ]; then
                say "still picture for ${el}s (< ${THRESH} B/s) - ending the capture"
                break
            fi
        else
            say "warming up: window ${el}s rate ${rate} B/s"
        fi
        [ $(( now - start )) -ge "$MAX" ] && { say "hard cap ${MAX}s reached - ending the capture"; break; }
        sleep "$INTERVAL"
    done
fi

say "SIGTERM -> monitor $MON (clean cap_stop: file finalised, card released)"
kill -TERM "$MON" 2>/dev/null
for _ in $(seq 1 20); do kill -0 "$MON" 2>/dev/null || break; sleep 1; done
if kill -0 "$MON" 2>/dev/null; then
    say "monitor still up after 20s; SIGTERM again and reaping the encoder"
    kill -TERM "$MON" 2>/dev/null; sleep 3
    pkill -TERM -f 'ffmpeg.*pctv-cap' 2>/dev/null
    pkill -TERM -f 'pctv_probe stream' 2>/dev/null
fi
sleep 2
say "final: $(ls -l --time-style=+%H:%M:%S "$FILE" 2>/dev/null | awk '{print $5" bytes, mtime "$6}')"
grep -E "capture stopped|fields \(" "${PCTV_END_STATELOG:-$HOME/.local/state/pctv-monitor.log}" 2>/dev/null | tail -2 | cut -c1-200 | tee -a "$LOG" >&2
say "done"
