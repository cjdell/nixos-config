#!/usr/bin/env bash
# pctv-recover.sh — revive a wedged PCTV 320cx and bring up the DVB stack.
#
# The DIB7000P behind the DiB0700 bridge stops answering I2C (every read
# returns 0x0000, writes stall EP0) after the stick has been left alone or
# after a failed driver attempt. A USB port reset fixes it — no unplug needed.
# After the reset the demod identifies (reg 768 = 0x01b3, reg 769 = 0x4000)
# and the kernel driver attaches the frontend + tuner.
#
# Usage: sudo scripts/pctv-recover.sh [devnum]
set -u
cd "$(dirname "$0")/.." || exit 1

# find the stick
line=$(timeout 10 lsusb -d 2304:022e || true)
if [ -z "$line" ]; then echo "PCTV 320cx (2304:022e) not on the bus — plug it in"; exit 1; fi
bus=$(echo "$line" | sed 's/Bus \([0-9]*\) .*/\1/'); dev=$(echo "$line" | sed 's/.*Device \([0-9]*\):.*/\1/')
echo "stick: bus $bus dev $dev"

# make sure nothing holds it while we reset
for d in /sys/bus/usb/devices/*:1.0; do
  case "$(cat "$d/../idVendor" 2>/dev/null)" in 2304)
    name=$(basename "$d"); intf=${name#*-}
    echo "$name" | sudo tee "/sys/bus/usb/drivers/dvb_usb_dib0700/unbind" >/dev/null 2>&1 || true;; esac
done
sleep 1

# port reset (the probe's handle dies in the process — that is expected)
sudo pctv-linux/pctv_probe reset 2>&1 | grep -v ctrl_ | tail -2
sleep 3

line2=$(timeout 10 lsusb -d 2304:022e || true)
[ -z "$line2" ] && { echo "stick vanished after reset — unplug/replug"; exit 1; }
echo "after reset: $line2"

# verify the demod answers before handing the stick to the kernel
sudo pctv-linux/pctv_probe identify 1 2>&1 | grep -v ctrl_ | head -3

# find the (new) interface name and bind the kernel driver
iface=$(ls /sys/bus/usb/devices/ | grep -E '^[0-9]+-[0-9]+:1\.0$' | while read -r i; do
  v=$(cat "/sys/bus/usb/devices/${i%%:1.0}/idVendor" 2>/dev/null); [ "$v" = 2304 ] && echo "$i"; done)
if [ -z "$iface" ]; then echo "could not find the stick's interface node"; exit 1; fi
echo "$iface" | sudo tee /sys/bus/usb/drivers/dvb_usb_dib0700/bind >/dev/null
sleep 4
echo "=== dmesg ==="
sudo dmesg | grep -iE "dib0700|dvb|xc2028|frontend" | tail -8
echo "=== nodes ==="
ls /dev/dvb/adapter0/ 2>/dev/null || echo "no /dev/dvb/adapter0 — frontend attach failed"
