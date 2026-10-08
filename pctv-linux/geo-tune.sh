#!/usr/bin/env bash
# Tune the CX25843 pixel/clock decimation (0x478/0x479) and report how the
# captured geometry responds. Goal: line period 720 with a field period of 312
# (PAL) or 262 (NTSC) and the lowest row-to-row difference (sharpness).
cd "$(dirname "$0")"
P="sudo -n ./pctv_probe"
IN="${1:-composite1}"
timeout 90 $P analog2 "$IN" pal 0f000000 0x82 100000 /tmp/pctv/prime.bin 0x0000 /tmp/v4l-cx25840.fw >/dev/null 2>&1
$P dwr 1286 0x0000 >/dev/null 2>&1
for spec in "0x1f 0x02" "0x8f 0x04" "0x11 0x01" "0x4f 0x01" "0x2f 0x01" "0xcf 0x02" "0x8f 0x01" "0x1f 0x01" "0xff 0x00"; do
  set -- $spec
  $P nwr1 1 0x44 0x478 $1 >/dev/null 2>&1
  $P nwr1 1 0x44 0x479 $2 >/dev/null 2>&1
  for x in 0f000100 0f000200 0f000400 0f000800; do $P arm $x >/dev/null 2>&1; done
  $P arm 0f110100 >/dev/null 2>&1
  timeout 25 $P cap2 0x82 2 /tmp/pctv/geo.bin >/dev/null 2>&1
  echo -n "dec=0x$2$1: "
  timeout 120 /tmp/pyn -c "
import numpy as np
d=np.fromfile('/tmp/pctv/geo.bin',dtype=np.uint8)
n=len(d)//1444
pay=d[:n*1444].reshape(-1,1444)[:,4:]
lum=pay[:,1::2]
best=[]
for W in range(660,780):
    f=lum.reshape(-1)
    m=len(f)//W*W
    a=f[:m].reshape(-1,W).astype(np.int16)
    best.append((float(np.abs(a[1:]-a[:-1]).mean()),W))
best.sort(); W=best[0][1]
f=lum.reshape(-1); m=len(f)//W*W; a=f[:m].reshape(-1,W)
fi=(a==0x10).mean(axis=1); vbi=np.nonzero(fi>0.9)[0]
sp=[]
if len(vbi)>2:
    prev=vbi[0]
    for r in vbi[1:]:
        if r-prev>3: sp.append(int(r-prev)); prev=r
print('line %d rowdiff %.2f  vbi spacings %s  luma max %d'%(W,best[0][0],sp[:6],lum.max()))
" 2>/dev/null
done
