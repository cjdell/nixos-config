#!/usr/bin/env bash
# capture-analog.sh - drive the PCTV 320cx analog path and save frames as PNGs.
#
#   sudo ./capture-analog.sh [input] [secs] [tag]
#     input : composite1 | composite3 | svideo1   (default composite1)
#     secs  : capture length (default 3)
#     tag   : output prefix (default cap-<input>-<epoch>)
#
# Output: /tmp/pctv/<tag>.bin  (raw bulk-IN stream)
#         pctv-linux/frames/<tag>-*.png  (candidate frames, several layouts)
#
# Requires: the device in a warm state (see scripts/pctv-recover.sh if i2c is dead),
#           /tmp/v4l-cx25840.fw, and /tmp/pyn (python3+numpy wrapper).
set -u
cd "$(dirname "$0")"
IN="${1:-composite1}"; SECS="${2:-3}"; TAG="${3:-cap-$IN-$(date +%s)}"
P="sudo -n ./pctv_probe"
RAW="/tmp/pctv/$TAG.bin"; mkdir -p /tmp/pctv frames

echo "== device check"
$P ver 2>&1 | tail -1
$P idrd 1 0x40 768 2>&1 | tail -1

echo "== decoder + demod bring-up (discards a short priming capture)"
timeout 90 $P analog2 "$IN" pal 0f100100 0x82 100000 /tmp/pctv/prime.bin 0x0000 /tmp/v4l-cx25840.fw 2>&1 |
  grep -E "demod id|cx25843 id|firmware|decoder:|0x803"

echo "== release every channel, then arm ANALOG mode (vendor payload 0f 11 01 00)"
for x in 0f000100 0f000200 0f000400 0f000800; do $P arm $x >/dev/null 2>&1; done
$P arm 0f110100 2>&1 | tail -1

echo "== capture ${SECS}s"
timeout $((SECS + 30)) $P cap2 0x82 "$SECS" "$RAW" 2>&1 | grep -E "captured|first"

echo "== decoder state after capture"
$P cxdump 2>&1 | grep -E "0x40d|0x40e|0x803|0x115|0x116"

echo "== frames"
timeout 300 /tmp/pyn img.py "$RAW" frames "$TAG" 2>&1 | grep -E "^\s+\S+\.png|framing|bytes, mean"
echo "raw: $RAW   frames: frames/$TAG-*.png"
