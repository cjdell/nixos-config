#!/usr/bin/env bash
set -euo pipefail

# sudo systemctl stop nfs-server
# sudo bash -c 'umount -f -l /exports/pxe-server-squashfs | true'
sudo nixos-rebuild switch --flake . --impure
sudo nixos-confirm
# sudo mount -a
# sudo systemctl start nfs-server
