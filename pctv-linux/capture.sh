#!/usr/bin/env bash
# Capture host-side USB traffic on the bus carrying the PCTV (bus 2), while a
# Windows capture attempt is made in the VM.
#
#   ./capture.sh <name> [seconds]
#
# Writes logs/raw-<name>.bin ; decode afterwards with:
#   ./parse.sh <name>
set -e
cd "$(dirname "$0")"
NAME=${1:-session}
SECS=${2:-900}
OUT="logs/raw-$NAME.bin"
rm -f "$OUT"
( setsid nohup timeout "$SECS" sh -c "sudo cat /dev/usbmon2 > '$OUT'" >/dev/null 2>&1 & )
sleep 2
echo "capturing bus 2 -> $OUT for ${SECS}s"
echo "start marker: $(date +%s)  ($(date))" | tee "logs/marker-$NAME.txt"
