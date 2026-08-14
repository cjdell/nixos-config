# NixOS Config

## Install

    git clone --depth 1 https://github.com/cjdell/nixos-config.git
    # (shallow clone; run `git fetch --unshallow` if you want the full history)

    cd nixos-config

    sudo -s

    scripts/create-partitions.sh
    scripts/mount-partitions.sh

    nixos-install --impure --root /mnt --flake .#hostname

    nixos-enter --root '/mnt'

    passwd cjdell

    exit

    mv /home/nixos/nixos-config /mnt/home/cjdell/
