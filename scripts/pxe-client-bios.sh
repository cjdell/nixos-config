#!/usr/bin/env bash
set -euo pipefail

qemu-system-x86_64 \
  -m 8192 \
  -accel kvm \
  -smp 4 \
  -netdev tap,id=net0,br=brlan,helper=$(type -p qemu-bridge-helper) \
  -device virtio-net-pci,netdev=net0 \
  -display vnc=:0 \
  -vga qxl \
  -boot n \
#   -drive file=FD14LITE.img,format=raw \
