#!/bin/sh
# Reload the freshly built pctv320cx module from /tmp/pctv-result.
#
# udev races us: as soon as the interface is driverless, modprobe can pull the
# installed (old) module from the store, and then `insmod` fails with
# "File exists" while the OLD code keeps running.  So: unbind, remove, insmod
# immediately, and retry if the race is lost.
set -u
KO=/tmp/pctv-result/lib/modules/7.2.3/updates/pctv320cx.ko.xz

[ -f "$KO" ] || { echo "no module at $KO (run ./build-module.sh)"; exit 1; }

# Drop the interface binding first: a bound USB interface pins the module.
for f in /sys/bus/usb/drivers/pctv320cx/*:*; do
	[ -e "$f" ] || continue
	dev=$(basename "$f")
	sudo sh -c "echo '$dev' > /sys/bus/usb/drivers/pctv320cx/unbind" 2>/dev/null
	done
sudo rmmod pctv320cx 2>/dev/null

for try in 1 2 3 4 5 6; do
	if sudo insmod "$KO" 2>/tmp/pctv-insmod.err; then
		echo "loaded $KO (attempt $try)"
		# Sanity: a fresh probe always logs this line.
		sudo dmesg | grep -q "Pinnacle PCTV 320cx analog capture ready" \
			&& { sudo dmesg | grep -E "pctv320cx" | tail -3; exit 0; }
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
echo "could not load the /tmp build (udev kept racing us)"; exit 1
