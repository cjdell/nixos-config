#!/usr/bin/env bash
# analog-try.sh — bring up the analog (composite / S-Video) path on the 320cx.
#
# Sequence: bridge bring-up + the Windows GPIO/demod register replay (regseq),
# then a CX2584x-style decoder bring-up at 7-bit 0x44 (the device the i2c scan
# finds there; it uses 16-bit register addressing like cx25840 and its writes
# round-trip), then REQUEST_ENABLE_VIDEO in analog mode and a bulk-IN read.
#
# The device must be free: echo 2-3:1.0 | sudo tee .../dvb_usb_dib0700/unbind
set -u
cd "$(dirname "$0")"
P="sudo ./pctv_probe"
EP="${1:-0x82}"
N="${2:-8192}"

$P ver | tail -1
$P regseq logs/analog-seq-ordered.txt 2>&1 | grep -E "replay:"

# --- decoder bring-up (cx25840-core.c semantics, 16-bit register addressing)
#   0x0000 video standard select: 0 = auto-detect
#   0x00f0 analog input select:   0xf0 = Composite1 / S-Video1 (luma1+chroma4)
#   0x0001 output control 0:      0x0f = outputs enabled
#   0x0011 vpo output control:    0xff = enable all VPO outputs
#   0x0012/0x0013 vpo format:     8-bit multiplexed (BT.656-style)
#   0x0115 |= 0x0c, 0x0116 |= 0x04  (cx25840_s_stream: enable video output)
for w in 0x0000:0x00 0x00f0:0xf0 0x0001:0x0f 0x0011:0xff 0x0012:0x03 0x0013:0x04 0x0115:0x0c 0x0116:0x04; do
    reg=${w%%:*}; val=${w##*:}
    $P nwr16 1 0x44 "$reg" "$val" >/dev/null 2>&1
    printf "  wrote reg %-7s = %-4s -> " "$reg" "$val"
    $P nrd16 1 0x44 "$reg" 1 2>&1 | grep -A1 "nrd16: 1 byte" | tail -1 | cut -c9-25
done

echo "--- decoder state ---"
for reg in 0x82 0x83 0x40d 0x40e 0x400; do
    printf "  reg %-5s =" $reg
    $P nrd16 1 0x44 $reg 1 2>&1 | grep -A1 "nrd16: 1 byte" | tail -1 | cut -c9-25
done

echo "--- enable analog streaming + bulk-IN read on ep $EP ---"
$P video on analog 2>&1 | grep -E "ENABLE_VIDEO|--" | tail -2
sleep 1
$P cap "$EP" "$N" /tmp/pctv/analog-cap.bin 2>&1 | grep -vE "ctrl_" | tail -3
ls -l /tmp/pctv/analog-cap.bin 2>/dev/null && timeout 20 nix shell nixpkgs#xd --command sh -c 'true' 2>/dev/null; xxd /tmp/pctv/analog-cap.bin 2>/dev/null | head -4
