#!/usr/bin/env bash
# Deploy a pi5-netboot build to the RPi 5 TFTP root on this host (zen3), and
# optionally power-cycle the Pi via the Home Assistant relay.
#
# Usage: sudo deploy-pi5.sh /path/to/pi5-netboot-build-dir [--reboot]
#
# The build dir is the output of:
#   nix build --impure path:pi5#packages.aarch64-linux.pi5-netboot -o <dir>
# (evaluated here, built on the MacBookAir via nix.buildMachines; the store
# closure lands in this host's /nix/store, which IS the NFS export the Pi
# mounts, so nothing else to copy.)
set -euo pipefail

BUILD="${1:?usage: deploy-pi5.sh <pi5-netboot-build-dir> [--reboot]}"
REBOOT="${2:-}"

[ -f "$BUILD/Image" ] && [ -f "$BUILD/initrd" ] && [ -d "$BUILD/nixStore" ] \
  || { echo "error: $BUILD is not a pi5-netboot build dir" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "error: must run as root (writes /etc/tftp)" >&2; exit 1; }

# Toplevel store path base name (e.g. abcd123...-nixos-system-pi5-...)
T=$(ls "$BUILD/nixStore/nix-store" | grep -m1 'nixos-system-pi5' \
  || { echo "error: no nixos-system-pi5 toplevel in $BUILD/nixStore/nix-store" >&2; exit 1; })

TFTP=/etc/tftp/e9cf02dc
mkdir -p "$TFTP"

# initrd (changes per build; ~29 MB)
if ! cmp -s "$BUILD/initrd" "$TFTP/initrd" 2>/dev/null; then
  cp "$BUILD/initrd" "$TFTP/initrd"
  echo "initrd: updated"
else
  echo "initrd: unchanged"
fi

# kernel Image (only changes when the kernel does; 38.5 MB)
if ! cmp -s "$BUILD/Image" "$TFTP/Image" 2>/dev/null; then
  cp "$BUILD/Image" "$TFTP/Image"
  echo "Image: updated"
else
  echo "Image: unchanged"
fi

# cmdline.txt carries the toplevel hash
CMDLINE="init=/nix/store/$T/init initrd=initrd loglevel=7 lsm=landlock,yama,bpf console=drm"
if [ ! -f "$TFTP/cmdline.txt" ] || [ "$(cat "$TFTP/cmdline.txt")" != "$CMDLINE" ]; then
  echo "$CMDLINE" > "$TFTP/cmdline.txt"
  echo "cmdline.txt: updated ($T)"
else
  echo "cmdline.txt: unchanged"
fi

if [ "$REBOOT" = "--reboot" ]; then
  # Power-cycle via the Home Assistant relay (see pi5-powercycle.sh).
  "${BASH_SOURCE[0]%/*}/pi5-powercycle.sh"
else
  echo "run with --reboot to power-cycle the Pi now"
fi
