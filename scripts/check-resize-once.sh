#!/usr/bin/env bash
# Read-only preflight for the one-time root resize defined in
# hosts/zen3-nixos/resize-once.nix.
#
# Resolves the partitions by fs UUID (this host has two NVMe drives whose
# kernel names swap between boots - the WD Black has been both nvme0n1 and
# nvme1n1), verifies that the disk still has the geometry the initrd resize
# script hardcodes, that the fs UUIDs match what NixOS mounts by, and that
# /home has enough room to shrink to ~681G. Makes NO changes.
#
# Run as root:  sudo scripts/check-resize-once.sh
set -euo pipefail

ROOT_UUID=4424123b-847e-4379-b505-520c85e522dd
HOME_UUID=a4284946-7e9b-4bcf-a94a-fa3e5a19e283

# expected current geometry (sectors), from `fdisk -l`
EXPECT_DISK_SIZE=1953525168
EXPECT_P3_START=1573990400
EXPECT_P3_SIZE=379534735
EXPECT_P5_START=1126400
EXPECT_P5_SIZE=1572864000

# target size
NEW_P5_GB=681

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

[ -e /dev/disk/by-uuid/$ROOT_UUID ] || fail "root partition (UUID $ROOT_UUID) not found"
[ -e /dev/disk/by-uuid/$HOME_UUID ] || fail "/home partition (UUID $HOME_UUID) not found"

P3=$(readlink -f /dev/disk/by-uuid/$ROOT_UUID)
P5=$(readlink -f /dev/disk/by-uuid/$HOME_UUID)
P3_NAME=$(basename "$P3")
P5_NAME=$(basename "$P5")
DISK_NAME=$(echo "$P3_NAME" | sed -E 's/p?[0-9]+$//')
DISK=/dev/$DISK_NAME

echo "resolved devices:  disk=$DISK  root=$P3  home=$P5"

d=$(cat /sys/class/block/$DISK_NAME/size)
p3s=$(cat /sys/class/block/$P3_NAME/start)
p3z=$(cat /sys/class/block/$P3_NAME/size)
p5s=$(cat /sys/class/block/$P5_NAME/start)
p5z=$(cat /sys/class/block/$P5_NAME/size)

[ "$d" = "$EXPECT_DISK_SIZE" ] || fail "disk size is $d sectors, expected $EXPECT_DISK_SIZE"
[ "$p3s" = "$EXPECT_P3_START" ] || fail "root partition start is $p3s, expected $EXPECT_P3_START"
[ "$p3z" = "$EXPECT_P3_SIZE" ] || fail "root partition size is $p3z, expected $EXPECT_P3_SIZE"
[ "$p5s" = "$EXPECT_P5_START" ] || fail "/home partition start is $p5s, expected $EXPECT_P5_START"
[ "$p5z" = "$EXPECT_P5_SIZE" ] || fail "/home partition size is $p5z, expected $EXPECT_P5_SIZE"

ru=$(blkid -s UUID -o value "$P3")
hu=$(blkid -s UUID -o value "$P5")
[ "$ru" = "$ROOT_UUID" ] || fail "root fs UUID is $ru"
[ "$hu" = "$HOME_UUID" ] || fail "/home fs UUID is $hu"

used_gb=$(df --output=used -BG /home | tail -1 | tr -dc '0-9')
free_gb=$(df --output=avail -BG /home | tail -1 | tr -dc '0-9')
echo "p5 (/home): used ~${used_gb}G, available ~${free_gb}G (target size ${NEW_P5_GB}G)"
[ "$used_gb" -lt "$NEW_P5_GB" ] || fail "used ${used_gb}G would not fit in a ${NEW_P5_GB}G /home"

if [ -e /boot/resize-once.flag ]; then
  echo "NOTE: stale /boot/resize-once.flag from the old (ESP-based) mechanism found - remove it:"
  echo "  sudo rm -f /boot/resize-once.flag"
fi

echo
echo "OK: disk geometry and fs UUIDs match the resize-once script."
echo "Resulting layout:  /  -> 250G,  /home -> ~${NEW_P5_GB}G."
echo
echo "To arm and run (as root):"
echo "  sudo nixos-rebuild switch --impure --flake . --max-jobs 1"
echo "  sudo nixos-confirm"
echo "  sudo touch /resize-once.flag"
echo "  sudo reboot"
echo "Then verify:  cat /resize-once.log && lsblk && df -h /"
