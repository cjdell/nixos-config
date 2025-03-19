# NixOS Config

## Install

    git clone https://github.com/cjdell/nixos-config.git

    cd nixos-config

    scripts/create-partitions.sh
    scripts/mount-partitions.sh

    nixos-install --impure --root /mnt --flake .#hostname

    cd /mnt

    nixos-enter

    passwd cjdell

    exit

    mv /home/nixos/nixos-config /mnt/home/cjdell/
