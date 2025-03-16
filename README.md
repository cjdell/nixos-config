# NixOS Config

## Scripts

    scripts/create-partitions.sh

## Install

    mount /dev/disk/by-label/ROOT /mnt
    mkdir -p /mnt/boot
    mount /dev/disk/by-label/BOOT /mnt/boot

    mkdir -p /mnt/home/cjdell

    git clone https://github.com/cjdell/nixos-config.git

    cd nixos-config

    nixos-install --impure --root /mnt --flake .#hostname
