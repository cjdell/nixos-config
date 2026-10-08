#!/bin/sh
# Reload the freshly built pctv320cx module from /tmp/pctv-result.
#
#   ./reload-module.sh [-f] [out-link]     (default out-link /tmp/pctv-result)
#
# The module path is resolved from the build output instead of hardcoded: the
# version directory changes with every kernel bump (7.2.3 -> 7.2.9 did exactly
# that, and the old hardcoded .../lib/modules/7.2.3/... path then just reported
# "no module at ...").  Same for the compression suffix - modules_install may
# write .ko, .ko.xz or .ko.zst depending on CONFIG_MODULE_COMPRESS.
#
# udev races us: as soon as the interface is driverless, modprobe can pull the
# installed (old) module from the store, and then `insmod` fails with
# "File exists" while the OLD code keeps running.  So: unbind, remove, insmod
# immediately, and retry if the race is lost.  This module has no srcversion
# field (modpost does not emit one for it), so "is this the build I just made?"
# is answered by the dmesg marker below: only probe lines appended after the
# insmod count.
set -u

FORCE=0
if [ "${1:-}" = "-f" ] || [ "${1:-}" = "--force" ]; then FORCE=1; shift; fi
OUT=${1:-/tmp/pctv-result}
RUN=$(uname -r)

KO=$(find "$OUT/lib/modules" -maxdepth 3 -name 'pctv320cx.ko*' 2>/dev/null | sort | head -1)
if [ -z "$KO" ]; then
	echo "no pctv320cx.ko* under $OUT/lib/modules — run ./build-module.sh first"
	exit 1
fi
BUILT=$(expr "$KO" : '.*/lib/modules/\([^/]*\)/.*')

if [ "$BUILT" != "$RUN" ] && [ "$FORCE" = 0 ]; then
	cat >&2 <<-EOF
		$KO is built for kernel $BUILT but this system runs $RUN.
		insmod would fail with "Invalid module format" (vermagic), which reads
		like a driver bug.  Rebuild against the running kernel:

		    ./build-module.sh            # builds against the flake's kernelPackages

		If the flake's kernelPackages is not what you booted, switch generations
		(or boot the newer one) first.  -f loads it anyway.
	EOF
	exit 1
fi

want=$(modinfo -F srcversion "$KO" 2>/dev/null)
echo "module: $KO (kernel $BUILT, srcversion ${want:-none})"

# Drop the interface binding first: a bound USB interface pins the module.
for f in /sys/bus/usb/drivers/pctv320cx/*:*; do
	[ -e "$f" ] || continue
	dev=$(basename "$f")
	sudo sh -c "echo '$dev' > /sys/bus/usb/drivers/pctv320cx/unbind" 2>/dev/null
	done
sudo rmmod pctv320cx 2>/dev/null

# If it is still loaded with nothing bound, the reference is the driver's own
# and rmmod will never succeed: on this kernel a registered usb_driver and its
# bound interfaces do not pin the module (btusb: 3 interfaces bound, refcnt 0),
# so a refcnt that stays >= 1 with no interface bound and no node open is a
# reference the driver took and never dropped.  Say that plainly instead of
# reporting the udev race, which is what the insmod "File exists" below looks
# like.
if lsmod | grep -q '^pctv320cx '; then
	ref=$(cat /sys/module/pctv320cx/refcnt 2>/dev/null)
	bound=$(ls -d /sys/bus/usb/drivers/pctv320cx/*:* 2>/dev/null | wc -l)
	if [ "${ref:-0}" -gt 0 ] && [ "$bound" -eq 0 ]; then
		cat >&2 <<-EOF
			cannot unload pctv320cx: refcnt=$ref with no interface bound and no
			video node open - the module holds a reference it never releases.
			The new build cannot be loaded in this boot.  Install it into the
			system (nixos-rebuild switch with hardware.pctv320cx.enable) and reboot,
			or reboot first and run this script before the card is probed.
		EOF
		exit 1
	fi
fi

# dmesg marker: "analog capture ready" is also in the log from the previous
# probe, so only lines appended after this point count as a fresh probe.
mark=$(sudo dmesg | wc -l)

for try in 1 2 3 4 5 6; do
	if sudo insmod "$KO" 2>/tmp/pctv-insmod.err; then
		echo "loaded $KO (attempt $try)"
		fresh=$(sudo dmesg | tail -n +"$((mark + 1))")
		if echo "$fresh" | grep -qE "pctv320cx|cx2584"; then
			echo "$fresh" | grep -E "pctv320cx|cx2584"
		else
			echo "no probe lines after insmod - the interface is unbound;"
			echo "bind it: echo 2-3:1.0 | sudo tee /sys/bus/usb/drivers/pctv320cx/bind"
		fi
		node=""
		for v in /dev/video*; do
			[ -e "$v" ] || continue
			case "$(v4l2-ctl -d "$v" -D 2>/dev/null)" in
			*PCTV*) node="$v" ;;
			esac
		done
		echo "video node: ${node:-none (probe did not register a node)}"
		exit 0
	fi
	if grep -qi "File exists" /tmp/pctv-insmod.err; then
		# udev won the race: remove the store module and try again.
		sudo rmmod pctv320cx 2>/dev/null
		sleep 0.5
		continue
	fi
	echo "insmod failed:"; cat /tmp/pctv-insmod.err
	exit 1
done
echo "could not load the $OUT build (udev kept racing us)"; exit 1
