#!/bin/sh
# Headless verification of the --master modes on the capture box: record SECS
# seconds in each mode with a given binary and report what came out.
#   MODES="uyvy ffv1 dvd" SECS=6 B=/path/bin/pctv-monitor sh test-masters.sh
# Prefix RT=1 to run each capture under a systemd-run scope with LimitRTPRIO so
# the SCHED_FIFO upgrade actually succeeds (a stale login session has rtprio 0).
set -u
B=${B:-pctv-monitor}
FP=/run/current-system/sw/bin/ffprobe
OUT=${OUT:-/tmp/masters}
SECS=${SECS:-6}
for m in ${MODES:-uyvy ffv1 dvd}; do
    rm -rf "$OUT-$m"; mkdir -p "$OUT-$m"
    echo "########## PCTV_MASTER=$m  (rtprio here: $(ulimit -r))"
    if [ "${RT:-0}" = 1 ]; then
        PFX="systemd-run --user --wait --collect -p LimitRTPRIO=20 /bin/sh -c"
        CMD="SDL_VIDEODRIVER=dummy PCTV_MASTER=$m exec '$B' --no-audio --capture --capture-seconds $SECS --out-dir '$OUT-$m'"
        timeout 120 $PFX "$CMD" >"$OUT-$m/$m.log" 2>&1
    else
        PCTV_MASTER=$m SDL_VIDEODRIVER=dummy timeout 120 "$B" --no-audio --capture \
            --capture-seconds "$SECS" --out-dir "$OUT-$m" >"$OUT-$m/$m.log" 2>&1
    fi
    echo "  monitor rc=$?"
    grep -E 'SCHED_FIFO|refused' "$OUT-$m/$m.log" | head -2 | sed 's/^/  RT: /'
    grep -E 'capture ->' "$OUT-$m/$m.log" | sed 's/^/  /'
    grep -E '[0-9]+ fields \(' "$OUT-$m/$m.log" | sed 's/^/  /'
    grep -E 'anomalies' -A1 "$OUT-$m/$m.log" | grep -v '^--' | grep -v 'anomalies' | head -2 | sed 's/^/  anom: /'
    f=$(ls -t "$OUT-$m"/pctv-cap-* 2>/dev/null | head -1)
    [ -n "$f" ] || { echo "  NO OUTPUT FILE"; continue; }
    sz=$(stat -c %s "$f")
    printf '  %s  %s B  ~%s MB/min\n' "$(basename "$f")" "$sz" "$(( sz * 60 / SECS / 1048576 ))"
    echo "  stream: $($FP -v error -select_streams v -show_entries stream=codec_name,width,height,pix_fmt,r_frame_rate,field_order -of csv=p=0 "$f" 2>/dev/null)"
    echo "  frames: flags=[$($FP -v error -select_streams v -show_frames -read_intervals '%+2' -show_entries frame=interlaced_frame,top_field_first -of csv=p=0 "$f" 2>/dev/null | tr -d ' ' | sort -u | paste -sd ' ' -)] count=$($FP -v error -count_frames -select_streams v -show_entries stream=nb_read_frames -of csv=p=0 "$f" 2>/dev/null) audio=$($FP -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 "$f" 2>/dev/null)"
    timeout 60 ${FO:-pctv-field-order} "$f" 2>/dev/null | sed 's/^/  /' || true
done
