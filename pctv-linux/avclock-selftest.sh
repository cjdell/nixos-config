#!/usr/bin/env bash
# avclock-selftest.sh - build and run the A/V clock unit test.
#
# The companion to capture-selftest.sh (field-level damage) and queue-selftest.sh
# (sink-level damage).  This one is the *clock*: it drives the real
# rs_reset/rs_run/rs_update out of pctv-monitor.c through simulated tapes - a
# crystal that is 450 ppm off, a hole in the PCM, a stalled sink - and checks the
# one thing a viewer notices: that the sound and the picture end up on the same
# tape position.  No deck, no card, no two hours of wall clock.
#
#   ./pctv-linux/avclock-selftest.sh [-v]
#
# -v keeps the controller's own log lines (what it decided, second by second).
#
# History: pctv-cap-20261104-015210.mkv finished 1.183 s of extra audio against
# 7294.96 s of picture - the sound more than a second behind the lips by the end -
# and every counter in the stop line read zero, because nothing measured what the
# two tracks disagreed by.  See docs/pctv-analog-capture.md §14.2d.
set -uo pipefail
cd "$(dirname "$0")"
FFLAGS=(-O2 -Wall -Wextra -Wno-unused-parameter)
DEV=$(nix build --no-link --print-out-paths nixpkgs#SDL2.dev)
OUT=$(nix build --no-link --print-out-paths nixpkgs#SDL2)
ADEV=$(nix build --no-link --print-out-paths nixpkgs#alsa-lib.dev)
ALIB=$(nix build --no-link --print-out-paths nixpkgs#alsa-lib)
BIN=/tmp/pctv-avclock-selftest
nix shell nixpkgs#gcc --command cc "${FFLAGS[@]}" -o "$BIN" avclock-selftest.c \
  -I"$DEV/include/SDL2" -I"$ADEV/include" \
  -L"$OUT/lib" -L"$ALIB/lib" -Wl,-rpath,"$OUT/lib" -Wl,-rpath,"$ALIB/lib" \
  -lSDL2 -lasound -lm -lpthread || { echo "BUILD FAILED" >&2; exit 2; }
"$BIN" "$@"
