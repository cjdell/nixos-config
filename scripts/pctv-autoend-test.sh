#!/usr/bin/env bash
# End-to-end harness for scripts/pctv-autoend.sh.
#
# Fakes the three things the watchdog looks at:
#   - a process whose command line ends in /pctv-monitor      (mon_pid)
#   - a process whose command line names ffmpeg + the capture (cap_file)
#   - a capture file that grows like a live tape and then stops (the detector)
# Timings are scaled to ~1 s so the confirmation window and the array-trim
# boundary (CONFIRM/INTERVAL+2 samples) are both crossed quickly.
#
# $1 = script to test. Exits 0 if the watchdog survived its window fill and
# then cleanly stopped the fake monitor.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=${1:-$root/scripts/pctv-autoend.sh}
FAKE=/tmp/pctvtest/autoend-run
rm -rf "$FAKE"; mkdir -p "$FAKE/bin" "$FAKE/vids"
LOG=$FAKE/watchdog.log

# No `exec` here: the watchdog matches these processes by command line, so the
# script's own argv must survive; sleep runs as a child and is reaped on TERM.
cat > "$FAKE/bin/pctv-monitor" <<'EOF'
#!/bin/sh
sleep 600 &
p=$!
trap 'kill $p 2>/dev/null; exit 0' TERM
wait $p
EOF
cp "$FAKE/bin/pctv-monitor" "$FAKE/bin/ffmpeg"
chmod +x "$FAKE/bin/"*
CAP=$FAKE/vids/pctv-cap-20261102-000000.mpg
: > "$CAP"

bash "$FAKE/bin/pctv-monitor" & MON=$!
bash "$FAKE/bin/ffmpeg" -o "$CAP" & FF=$!
sleep 1

PCTV_VIDEOS=$FAKE/vids PCTV_END_LOG=$LOG PCTV_END_INTERVAL=1 \
PCTV_END_CONFIRM=6 PCTV_END_RATE=150000 PCTV_END_MAX=600 \
    bash "$SCRIPT" & WD=$!

# ~800 kB/s of "programme" for 20 s, then the tape ends: file stops growing.
( for i in $(seq 1 20); do head -c 800000 /dev/urandom >> "$CAP"; sleep 1; done ) &
GROW=$!

for i in $(seq 1 60); do
    kill -0 $WD 2>/dev/null || break
    sleep 1
done
# cleanup whatever is left
kill $GROW $MON $FF 2>/dev/null
wait 2>/dev/null

echo "--- watchdog log ---"; cat "$LOG"
echo "--- verdict ---"
if ! kill -0 $WD 2>/dev/null; then
    if grep -q "unbound variable" "$LOG"; then
        echo "FAIL: watchdog died on an unbound variable"; exit 1
    fi
    if grep -q "still picture" "$LOG" && grep -q "SIGTERM" "$LOG"; then
        echo "PASS: survived the window fill, detected the still, stopped the monitor"
        exit 0
    fi
    echo "FAIL: exited without detecting the still picture"; exit 1
fi
echo "FAIL: watchdog still running (never triggered)"; kill $WD 2>/dev/null; exit 1
