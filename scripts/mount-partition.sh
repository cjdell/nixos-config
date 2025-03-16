#!/run/current-system/sw/bin/bash

mount /dev/disk/by-label/ROOT /mnt
mkdir -p /mnt/boot
mount /dev/disk/by-label/BOOT /mnt/boot
