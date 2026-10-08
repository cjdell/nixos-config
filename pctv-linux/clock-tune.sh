#!/usr/bin/env bash
# clock-tune.sh - sweep the CX25843 clock/decimation registers and score the
# resulting picture: best framing period + row-to-row difference (lower = the
# decoder's pixel clock is locked to the source, i.e. no 45-degree shear).
cd "$(dirname "$0")"
P="sudo -n ./pctv_probe"
IN="${1:-composite1}"
timeout 90 $P analog2 "$IN" pal 0f000000 0x82 100000 /tmp/pctv/prime.bin 0x0000 /tmp/v4l-cx25840.fw >/dev/null 2>&1
$P dwr 1286 0x0000 >/dev/null 2>&1

score() {
  timeout 200 /tmp/pyn -c "
import numpy as np
d=np.fromfile('/tmp/pctv/clk.bin',dtype=np.uint8)
n=len(d)//1444
flat=d[:n*1444].reshape(-1,1444)[:,4:][:,1::2].reshape(-1).astype(np.float32)
best=[]
for P in range(700,745):
    idx=(1000+np.arange(400))[:,None]*P+np.arange(720)[None,:]
    if idx.max()>=len(flat): continue
    im=flat[idx]
    best.append((float(np.abs(np.diff(im,axis=0)).mean()),P))
best.sort()
P=best[0][1]
idx=(1000+np.arange(400))[:,None]*P+np.arange(720)[None,:]
im=flat[idx]
print('bestP %3d  dV %5.2f  dH %5.2f  luma %3d'%(P,best[0][0],float(np.abs(np.diff(im,axis=1)).mean()),int(im.max())))
" 2>/dev/null
}
run() {
  for x in 0f000100 0f000200 0f000400 0f000800; do $P arm $x >/dev/null 2>&1; done
  $P arm 0f110100 >/dev/null 2>&1
  timeout 25 $P cap2 0x82 2 /tmp/pctv/clk.bin >/dev/null 2>&1
  printf "%-34s %s\n" "$1" "$(score)"
}
run "baseline 478/479=0x021f 47a/47b=0x021f"
for spec in "0x8f 0x04" "0x2f 0x01" "0x11 0x01" "0x1f 0x01" "0xff 0x00" "0x5b 0x00" "0x2c 0x00" "0x16 0x00"; do
  set -- $spec
  $P nwr1 1 0x44 0x478 $1 >/dev/null 2>&1; $P nwr1 1 0x44 0x479 $2 >/dev/null 2>&1
  $P nwr1 1 0x44 0x47a $1 >/dev/null 2>&1; $P nwr1 1 0x44 0x47b $2 >/dev/null 2>&1
  run "dec=0x$2$1"
done
$P nwr1 1 0x44 0x478 0x1f >/dev/null 2>&1; $P nwr1 1 0x44 0x479 0x02 >/dev/null 2>&1
$P nwr1 1 0x44 0x47a 0x1f >/dev/null 2>&1; $P nwr1 1 0x44 0x47b 0x02 >/dev/null 2>&1
for spec in "0x01 0x00" "0x02 0x00" "0x04 0x00" "0x08 0x00"; do
  set -- $spec
  $P nwr1 1 0x44 0x887 $1 >/dev/null 2>&1; $P nwr1 1 0x44 0x888 $2 >/dev/null 2>&1
  run "887/888=$1/$2"
done
$P nwr1 1 0x44 0x887 0x00 >/dev/null 2>&1; $P nwr1 1 0x44 0x888 0x00 >/dev/null 2>&1
