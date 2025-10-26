#!/usr/bin/env bash

nix flake update pxe-server
# sudo umount -f -l /exports/pxe-server-nix-store
sudo umount -f -l /exports/pxe-server-squashfs
sudo nixos-rebuild switch --flake . --impure
