#!/usr/bin/env bash
set -euo pipefail

OVMF_PATH=$(nix build --print-out-paths nixpkgs#OVMF.fd)

mkdir -p ./tmp

cp $OVMF_PATH/FV/OVMF_CODE.fd ./tmp
cp $OVMF_PATH/FV/OVMF_VARS.fd ./tmp

sudo chown cjdell:users ./tmp/*.fd
chmod +xwr ./tmp/*.fd

qemu-system-x86_64 \
  -m 8192 \
  -cpu host \
  -accel kvm \
  -smp 4 \
  -machine q35,smm=on -global driver=cfi.pflash01,property=secure,value=on \
  -object rng-random,id=virtio-rng0,filename=/dev/urandom \
  -device virtio-rng-pci,rng=virtio-rng0,id=rng0,bus=pcie.0,addr=0x9 \
  -netdev tap,id=net0,br=brlan,helper=$(type -p qemu-bridge-helper) \
  -device virtio-net-pci,netdev=net0 \
  -drive file=./tmp/OVMF_CODE.fd,if=pflash,format=raw,unit=0,readonly=on \
  -drive file=./tmp/OVMF_VARS.fd,if=pflash,format=raw,unit=1 \
  -display vnc=:0 \
  -vga qxl \
  -boot n \
