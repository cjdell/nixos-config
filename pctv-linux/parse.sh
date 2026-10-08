#!/usr/bin/env bash
# Decode a capture and (optionally) slice it by wall-clock time.
#
#   ./parse.sh <name>                    full decode
#   ./parse.sh <name> --since EPOCH      events at/after EPOCH
#   ./parse.sh <name> --since EPOCH --until EPOCH
#   ./parse.sh <name> --new              only vendor setups not seen in the
#                                        baseline capture (logs/baseline.parsed)
set -e
cd "$(dirname "$0")"
NAME=${1:?usage: parse.sh <name> [slice args]}
RAW="logs/raw-$NAME.bin"
[ -f "$RAW" ] || { echo "no $RAW"; exit 1; }
OUT="logs/$NAME.parsed"
nix shell nixpkgs#python3 --command python3 monparse.py "$RAW" > "$OUT" 2>/dev/null
echo "-> $OUT ($(wc -l < "$OUT") events)"

SINCE=""; UNTIL=""
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --since) SINCE=$2; shift 2;;
    --until) UNTIL=$2; shift 2;;
    *) shift;;
  esac
done

if [ -n "$SINCE" ] || [ -n "$UNTIL" ]; then
  awk -v s="${SINCE:-0}" -v u="${UNTIL:-99999999999}" '
    { ts = $1 + 0 } ts >= s && ts <= u { print }' "$OUT"
fi
