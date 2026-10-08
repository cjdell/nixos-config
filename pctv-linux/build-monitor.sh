#!/usr/bin/env bash
# build pctv-monitor (SDL2 live GUI).  pctv_probe is built by ./build.sh.
set -e
cd "$(dirname "$0")"
DEV=$(nix build --no-link --print-out-paths nixpkgs#SDL2.dev)
OUT=$(nix build --no-link --print-out-paths nixpkgs#SDL2)
exec nix shell nixpkgs#gcc --command \
  cc -O2 -Wall -o pctv-monitor pctv-monitor.c \
     -I"$DEV/include/SDL2" -L"$OUT/lib" -Wl,-rpath,"$OUT/lib" -lSDL2
