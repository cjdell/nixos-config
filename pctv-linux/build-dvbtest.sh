#!/usr/bin/env bash
# build dvbtest (DVB-T streaming baseline probe)
set -e
cd "$(dirname "$0")"
K=$(nix build --no-link --print-out-paths nixpkgs#linuxHeaders)
exec nix shell nixpkgs#gcc --command cc -O2 -Wall -I"$K/include" -o dvbtest dvbtest.c
