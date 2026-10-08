#!/usr/bin/env bash
# color-test.sh - bring the PCTV 320cx analog path up once, then sweep CX25843
# register writes and measure whether CHROMA appears.
#
# The analog bus is BT.656-ish 4:2:2: 1444-byte blocks, payload 1440 bytes =
# [Cr Y Cb Y] x 360 per line.  With chroma working the EVEN bytes (b0/b2) vary;
# today they are pinned at exactly 0x80 (neutral) -> monochrome picture.
#
# Usage: color-test.sh [input] [variant ...]
#   variant = "label:reg=val[,reg=val...]"   (reg/val accept 0x..)
# With no variants it runs the built-in sweep.
set -u
cd "$(dirname "$0")"
P="sudo -n ./pctv_probe"
IN="${1:-composite1}"; shift || true
OUT=/tmp/pctv/color; mkdir -p "$OUT"

echo "== bring-up on $IN"
timeout 120 $P analog2 "$IN" pal 0f000000 0x82 100000 /tmp/pctv/prime.bin 0x0000 /tmp/v4l-cx25840.fw 2>&1 |
  grep -E "decoder:|cx25843 id|input "
$P dwr 1286 0x0000 >/dev/null 2>&1

# report the decoder registers we care about
REGS="0x400 0x401 0x404 0x420 0x423 0x47b"
dump() {
  timeout 30 $P cxr 0x400 0x30 2>/dev/null | grep '^cx' | grep -E '400|401|404|420|423|47b' | tr '\n' ' '
  echo
}

cap() { # $1 label
  for x in 0f000100 0f000200 0f000400 0f000800; do $P arm $x >/dev/null 2>&1; done
  $P arm 0f110100 >/dev/null 2>&1
  timeout 25 $P cap2 0x82 2 "$OUT/$1.bin" >/dev/null 2>&1
  timeout 120 /tmp/pyn -c "
import numpy as np,sys
try: d=np.fromfile('$OUT/$1.bin',dtype=np.uint8)
except OSError: print('$1: no capture'); sys.exit()
n=len(d)//1444
if n<20: print('%-30s no data (%d bytes)'%('$1',len(d))); sys.exit()
pay=d[:n*1444].reshape(-1,1444)[:,4:]
ev=pay[:,0::2]
print('%-30s chroma std %6.2f uniq %3d range %3d..%3d | luma %3d..%3d'%(
  '$1',ev.std(),len(np.unique(ev)),ev.min(),ev.max(),pay[:,1::2].min(),pay[:,1::2].max()))
"
}

run() { # $1 label, $2... reg=val writes
  local label="$1"; shift
  for kv in "$@"; do
    reg="${kv%%=*}"; val="${kv##*=}"
    $P cxw "$reg" "$val" >/dev/null 2>&1
  done
  sleep 1
  cap "$label"
}

echo "== baseline"
dump
cap baseline

if [ $# -gt 0 ]; then
  for v in "$@"; do
    label="${v%%:*}"; rest="${v#*:}"
    IFS=',' read -r -a kvs <<< "$rest"
    echo "== $label ($rest)"
    run "$label" "${kvs[@]}"
    dump
  done
else
  echo "== built-in sweep"
  run ckill_off      0x401=0xc0
  run ckill_cagc_off 0x401=0x80
  run sat_max        0x420=0xfe
  run ckill_satmax   0x401=0xc0    0x420=0xfe
  run bt601_fmt      0x404=0x30
  run all_chroma     0x400=0x04 0x401=0xc0 0x420=0xfe
  dump
fi
echo "captures in $OUT"
