#!/bin/sh
# Post-boot / post-insmod check for the pctv320cx driver
# (run on macbook-pro-2009-nixos).  Finds the pctv node itself - it is not
# necessarily /dev/video2 (the iSight camera owns video1/2 on this host).
set -u
V4L2CTL=$(command -v v4l2-ctl || echo /nix/store/*-v4l-utils*/bin/v4l2-ctl)

echo "== module =="
lsmod | grep -E "pctv320cx|videobuf2|videodev" || echo "NOT LOADED"
echo "== dvb stack (must be empty) =="
lsmod | grep -E "^(dvb_usb|dvb_core|dib)" || echo "clean"

echo "== dmesg =="
sudo dmesg | grep -iE "pctv320cx|cx2584" | tail -25

echo "== find the pctv node =="
NODE=""
for v in /dev/video*; do
	[ -e "$v" ] || continue
	name=$($V4L2CTL -d "$v" --info 2>/dev/null | sed -n 's/.*Card type *: *//p')
	case "$name" in
	*PCTV*) NODE="$v";;
	esac
done
if [ -z "$NODE" ]; then
	echo "no PCTV video node (driver not bound / probe failed)"
	exit 1
fi
echo "PCTV node: $NODE"

echo "== signal / input =="
$V4L2CTL -d "$NODE" --get-input 2>/dev/null
$V4L2CTL -d "$NODE" --get-tuner 2>/dev/null | grep -E "Signal|Name"

echo "== format =="
$V4L2CTL -d "$NODE" --all 2>/dev/null | sed -n '1,40p'

echo "== capture 10 frames =="
if timeout 30 $V4L2CTL -d "$NODE" --stream-mmap --stream-count=10 \
		--stream-to=/tmp/pctv-driver-test.raw >/dev/null 2>&1; then
	echo "OK $NODE -> $(stat -c%s /tmp/pctv-driver-test.raw) bytes ($(($(stat -c%s /tmp/pctv-driver-test.raw) / 829440)) frames)"
	ffmpeg -hide_banner -loglevel error -f rawvideo -pix_fmt uyvy422 \
		-s 720x576 -i /tmp/pctv-driver-test.raw -frames:v 1 \
		-y /tmp/pctv-driver-test.png && echo "frame -> /tmp/pctv-driver-test.png"
else
	echo "FAIL: capture timed out"
fi
