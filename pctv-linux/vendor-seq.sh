#!/usr/bin/env bash
# Replay the vendor's EXACT analog bring-up (logs/analog-seq-ordered.txt),
# then arm the analog payload and capture. Last untried combination.
cd /home/cjdell/nixos-config/pctv-linux
P="sudo -n ./pctv_probe"
echo "== decoder bring-up (CX25843 firmware + std + input)"
timeout 90 $P analog2 composite1 pal 0f000000 0x82 100000 /tmp/pctv/ws-prim.bin 0x0000 /tmp/v4l-cx25840.fw 2>&1 |
  grep -E "demod id|cx25843 id|firmware|decoder:|arm"
echo "== replay the Windows analog register sequence"
timeout 300 $P regseq logs/analog-seq-ordered.txt 2>&1 | tail -6
echo "== release channels, arm analog"
for x in 0f000100 0f000200 0f000400 0f000800; do $P arm $x >/dev/null 2>&1; done
$P arm 0f110100 2>&1 | tail -1
echo "== capture"
timeout 30 $P cap2 0x82 3 /tmp/pctv/ws-analog.bin 2>&1 | grep -E "captured|first"
echo "== also try the MPEG arm with the same demod state"
for x in 0f000100 0f000200 0f000400 0f000800; do $P arm $x >/dev/null 2>&1; done
$P arm 0f100100 2>&1 | tail -1
timeout 30 $P cap2 0x82 3 /tmp/pctv/ws-mpeg.bin 2>&1 | grep -E "captured"
echo "== stats"
for f in /tmp/pctv/ws-analog.bin /tmp/pctv/ws-mpeg.bin; do
  echo -n "$f: "; timeout 120 /tmp/pyn -c "
import numpy as np
d=np.fromfile('$f',dtype=np.uint8)
if len(d)<1000: print('tiny'); raise SystemExit
h=np.bincount(d,minlength=256); n=len(d)//188
ts=float((d[:n*188].reshape(-1,188)[:,0]==0x47).mean()) if n>10 else 0
print('n=%d distinct=%3d frac80=%.3f mean=%6.1f std=%5.1f ts47=%.3f'%(len(d),int((h>0).sum()),np.mean(d==0x80),d.mean(),d.std(),ts))
" 2>/dev/null
done
