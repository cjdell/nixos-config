#!/usr/bin/env bash
# build pctv-monitor (SDL2 live GUI + ALSA audio meter/MPEG-2 capture).
# pctv_probe is built by ./build.sh; the monitor only spawns it.
#
# ffmpeg is looked up on PATH at capture time; point at a specific build with
# --ffmpeg <path> or PCTV_FFMPEG=<path>.
set -euo pipefail
cd "$(dirname "$0")"
DEV=$(nix build --no-link --print-out-paths nixpkgs#SDL2.dev)
OUT=$(nix build --no-link --print-out-paths nixpkgs#SDL2)
ADEV=$(nix build --no-link --print-out-paths nixpkgs#alsa-lib.dev)
ALIB=$(nix build --no-link --print-out-paths nixpkgs#alsa-lib)
exec nix shell nixpkgs#gcc --command cc -O2 -Wall -Wextra -Wno-unused-parameter \
  -o pctv-monitor pctv-monitor.c \
  -I"$DEV/include/SDL2" -I"$ADEV/include" \
  -L"$OUT/lib" -L"$ALIB/lib" -Wl,-rpath,"$OUT/lib" -Wl,-rpath,"$ALIB/lib" \
  -lSDL2 -lasound -lm -lpthread
