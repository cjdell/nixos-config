#!/usr/bin/env bash
# build pctv_probe (userspace DiB0700 probe tool)
set -e
cd "$(dirname "$0")"
DEV=$(nix build --no-link --print-out-paths nixpkgs#libusb1.dev 2>/dev/null || nix build --no-link --print-out-paths nixpkgs#libusb1)
RUN=$(nix build --no-link --print-out-paths nixpkgs#libusb1)
exec nix shell nixpkgs#clang nixpkgs#gcc --command cc -O2 -Wall -I"$DEV/include" -o pctv_probe probe.c -L"$RUN/lib" -lusb-1.0
