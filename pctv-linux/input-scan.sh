#!/usr/bin/env bash
# input-scan.sh - walk every CX25843 video input on the PCTV 320cx and report
# whether the decoder sees a signal on it.
#
#   ./input-scan.sh                 use the pctv_probe on PATH
#   ./input-scan.sh ./pctv_probe    use a locally built one
#
# The card has one composite (yellow RCA) + one S-Video connector, but the
# CX25843 has 8 composite VINs and 4 S-Video luma/chroma pairs.  This tells you
# which VIN this board actually wires each connector to (useful when a
# connector appears dead).  Control transfers only: it does not need the bulk
# stream, so it can run while pctv-monitor holds the device.
#
# 0x40d low nibble = detected standard, 0x40e bit5 (0x20) = signal present.
set -u
P="${1:-pctv_probe}"
command -v "$P" >/dev/null 2>&1 || [ -x "$P" ] || { echo "no probe: $P" >&2; exit 1; }
mkdir -p /tmp/pctv

rd() { timeout 15 "$P" cxr "$1" 1 2>/dev/null | awk 'END{print $NF}'; }

scan() { # label reg mode
  timeout 15 "$P" cxw 0x103 "$2" >/dev/null 2>&1
  timeout 15 "$P" cxw 0x401 "$3" >/dev/null 2>&1
  sleep 1
  d=$(rd 0x40d); e=$(rd 0x40e)
  sig=-
  [ -n "$e" ] && [ $((0x$e & 0x20)) -ne 0 ] && sig=SIGNAL
  printf '  %-14s mux 0x%02x 0x40d=%s 0x40e=%s  %s\n' "$1" "$2" "$d" "$e" "$sig"
}

echo "Composite VINs (INPUT_MODE=composite, 0x401=0x00):"
for n in 1 2 3 4 5 6 7 8; do scan "composite$n" $((0xf0 + n - 1)) 0x00; done

echo "S-Video luma/chroma pairs (INPUT_MODE=s-video, 0x401=0x02):"
# values mirror pctv_probe's svideo map {0x510,0x620,0x730,0x840}
scan "svideo1" 0xd0 0x02
scan "svideo2" 0xe1 0x02
scan "svideo3" 0x32 0x02
scan "svideo4" 0x73 0x02

echo "done (restore a real input with: $P cxw 0x103 0xd0; $P cxw 0x401 0x02)"
