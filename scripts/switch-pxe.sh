#!/usr/bin/env bash
set -euo pipefail

# sudo systemctl stop nfs-server
# sudo bash -c 'umount -f -l /exports/pxe-server-squashfs | true'
sudo nixos-rebuild switch --flake . --impure
# nixos-confirm may be absent (autoRollback temporarily disabled): skip quietly
if command -v nixos-confirm >/dev/null 2>&1; then
  sudo nixos-confirm
fi
# sudo mount -a
# sudo systemctl start nfs-server
