#!/usr/bin/env bash
# capture-live.sh [input] [secs] [tag] [field-index] - live analog capture
# through to a clean PNG.
#
# Bring-up (all through the demod i2c gate, 2-byte register addressing):
#   analog2 ...            load CX25843 firmware, select input, PAL std
#   dwr 1286 0x0000        demod HIGH_Z so the CX25843 is the only bus driver
#   cxw 0x401 0xc0         CKILLEN (bit6) off -> chroma passes; CAGCEN on
#   cxw 0x420 0x80         saturation (0x80 = 1.0x)
#   cxw 0x47a 0x90         luma lpf 2, chroma lpf 1
#   cxw 0x47b 0x20         comb
#   arm 0f 12 01 00        ENABLE_VIDEO: streaming on, ANALOG framing, mode 2
#
# Mode 2 is the important bit.  Mode 1 (0x11) hands over only the active part
# of each line and runs at 15.3 MB/s, below the 27.0 MB/s a PAL signal needs,
# so the bridge drops a third of all lines.  Mode 2 (0x12) passes the whole
# BT.656 line and sustains 25.6 MB/s = ~95% of lines; the residue is scattered
# singles, small enough to simply rescale away (see decode-bt656.py).
set -u
cd "$(dirname "$0")"
IN="${1:-composite1}"; SECS="${2:-3}"; TAG="${3:-live-$IN-$(date +%s)}"
FIELD="${4:-0}"
P="sudo -n ./pctv_probe"; mkdir -p /tmp/pctv snapshots

$P ver 2>&1 | tail -1
timeout 90 $P analog2 "$IN" pal 0f000000 0x82 100000 /tmp/pctv/prime.bin 0x0000 /tmp/v4l-cx25840.fw 2>&1 |
  grep -E "cx25843 id|input |decoder:"
$P dwr 1286 0x0000 >/dev/null 2>&1
$P cxw 0x401 0xc0 >/dev/null 2>&1     # colour killer off  -> colour
$P cxw 0x420 0x80 >/dev/null 2>&1     # saturation
$P cxw 0x470 0x84 >/dev/null 2>&1     # hblank (BT.656 blanking is fixed anyway)
$P cxw 0x471 0x00 >/dev/null 2>&1     # hactive low nibble
$P cxw 0x472 0x2d >/dev/null 2>&1     # hactive = 720
$P cxw 0x47a 0x90 >/dev/null 2>&1     # luma lpf 2 / chroma lpf 1
$P cxw 0x47b 0x20 >/dev/null 2>&1     # comb
for x in 0f000100 0f000200 0f000400 0f000800; do $P arm $x >/dev/null 2>&1; done
$P arm 0f120100 >/dev/null 2>&1       # ENABLE_VIDEO: analog framing, MODE 2
timeout $((SECS + 30)) $P cap2 0x82 "$SECS" "/tmp/pctv/$TAG.bin" 2>&1 | grep -E "captured"

RAW="/tmp/pctv/$TAG.bin"
if [ "$FIELD" = "best" ]; then IDX=-1; else IDX="$FIELD"; fi
for mode in "--chroma-median 3x3" "--grey"; do
  EXT=colour; [ "$mode" = "--grey" ] && EXT=grey
  timeout 900 /tmp/pyn decode-bt656.py "$RAW" snapshots "$TAG" --index "$IDX" $mode 2>&1 |
    grep -E "field |chose|recovered|rescaling|wrote"
  [ -f "snapshots/$TAG-$IDX.png" ] && mv "snapshots/$TAG-$IDX.png" "snapshots/$TAG-$EXT.png"
done
echo "snapshots/$TAG-colour.png  snapshots/$TAG-grey.png   (raw: $RAW)"
echo "field heights in this capture:"
timeout 300 /tmp/pyn -c "
import numpy as np
src=open('decode-bt656.py').read(); src=src[:src.rfind('main()')]
ns={}; exec(src,ns)
d=np.fromfile('$RAW',dtype=np.uint8)
Y,Cb,Cr,F,V=ns['parse'](d)
r=ns['field_runs'](V)
h=[b-a for a,b in r]
import collections
print(' ',collections.Counter(h).most_common(8),'  complete(288):',sum(1 for x in h if x>=288),'/',len(h))
"
