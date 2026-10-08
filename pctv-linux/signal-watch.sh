#!/usr/bin/env bash
# signal-watch.sh - watch the CX25843 "video signal present" bit live.
#
#   ./signal-watch.sh [input] [seconds]      default: composite1, 0 = forever
#   ./signal-watch.sh --sweep                try every composite VIN once
#
# Reads only the decoder status registers (control transfers), so it runs
# alongside a live pctv-monitor / pctv_probe stream.  Use it to watch for a
# signal while you reseat the pigtail or power-cycle the source:
#
#   0x40e bit 5 (0x20) set = sync present.
#
# The card must already be brought up (bridge warm).  If every read shows
# 0x4a the decoder is seeing no sync on that input at all.
set -u
P="${PCTV_PROBE:-pctv_probe}"
[ -x ./pctv_probe ] && P=./pctv_probe   # prefer the local build
IN="${1:-composite1}"
SECS="${2:-0}"

rd() { timeout 12 sudo -n "$P" cxr "$1" 1 2>/dev/null | awk 'END{print $NF}'; }

report() { # label
  local d e
  d=$(rd 0x40d); e=$(rd 0x40e)
  local sig=NO
  [ -n "$e" ] && [ $((0x$e & 0x20)) -ne 0 ] && sig=SIGNAL
  printf '%s  %-12s 0x40d=%s 0x40e=%s  %s\n' \
    "$(date +%H:%M:%S)" "$1" "${d:-??}" "${e:-??}" "$sig"
  [ "$sig" = SIGNAL ]
}

if [ "$IN" = "--sweep" ]; then
  for n in 1 2 3 4 5 6 7 8; do
    timeout 12 sudo -n "$P" cxw 0x103 $((0xf0 + n - 1)) >/dev/null 2>&1
    timeout 12 sudo -n "$P" cxw 0x401 0x00 >/dev/null 2>&1
    sleep 1
    report "composite$n"
  done
  exit 0
fi

echo "watching $IN (0x40e bit5 = sync) - Ctrl-C to stop"
stop=$(( SECS > 0 ? $(date +%s) + SECS : 0 ))
while :; do
  report "$IN" && :
  [ "$stop" -ne 0 ] && [ "$(date +%s)" -ge "$stop" ] && break
  sleep 1
done
