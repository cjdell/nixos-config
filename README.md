# NixOS Config

## Install

    git clone https://github.com/cjdell/nixos-config.git

    cd nixos-config

    sudo -s

    scripts/create-partitions.sh
    scripts/mount-partitions.sh

    nixos-install --impure --root /mnt --flake .#hostname

    nixos-enter --root '/mnt'

    passwd cjdell

    exit

    mv /home/nixos/nixos-config /mnt/home/cjdell/
