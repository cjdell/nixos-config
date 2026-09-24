#!/usr/bin/env bash
#
# flash.sh - build and flash NanoThermistor.c onto an Arduino Nano (ATmega328P)
#
#   ./flash.sh                       # autodetect the port, build + flash
#   ./flash.sh -p /dev/ttyUSB0       # explicit port
#   ./flash.sh -b 115200             # force a bootloader baud rate
#   ./flash.sh --build-only          # compile to NanoThermistor.hex, no flash
#
# Without a -b flag it tries 115200 (optiboot) then 57600 (old bootloader).
# avr-gcc/avrdude are picked up from PATH, or provided via `nix shell` if
# absent (this repo's hosts are NixOS).
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/NanoThermistor.c"
OUT="$HERE/NanoThermistor"
MCU=atmega328p
F_CPU=16000000UL

PORT=""
BAUD=""
BUILD_ONLY=0

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        -p|--port)       PORT="$2"; shift 2 ;;
        -b|--baud)       BAUD="$2"; shift 2 ;;
        --build-only)    BUILD_ONLY=1; shift ;;
        -h|--help)       usage 0 ;;
        *) echo "unknown argument: $1" >&2; usage 1 ;;
    esac
done

# --- toolchain: use PATH, else pull from nix ------------------------------
NEED_NIX=0
command -v avr-gcc  >/dev/null 2>&1 || NEED_NIX=1
command -v avrdude  >/dev/null 2>&1 || NEED_NIX=1

# nixpkgs has no top-level 'avrgcc' - the AVR toolchain lives under
# pkgsCross.avr (gcc + binutils for avr-objcopy/avr-size, plus avr-libc).
NIX_TOOLS=(nixpkgs#pkgsCross.avr.buildPackages.gcc
           nixpkgs#pkgsCross.avr.buildPackages.binutils
           nixpkgs#pkgsCross.avr.libc
           nixpkgs#avrdude)

run() {
    if [ "$NEED_NIX" = 1 ]; then
        nix shell "${NIX_TOOLS[@]}" -c "$@"
    else
        "$@"
    fi
}
if [ "$NEED_NIX" = 1 ]; then
    echo "avr-gcc/avrdude not in PATH - using the pkgsCross.avr toolchain via 'nix shell'"
fi

# --- build ----------------------------------------------------------------
echo ">> compiling $SRC"
run avr-gcc -mmcu="$MCU" -DF_CPU="$F_CPU" -Os -Wall -Wextra \
    -ffunction-sections -fdata-sections \
    -o "$OUT.elf" "$SRC" -Wl,--gc-sections -lm

run avr-objcopy -O ihex -R .eeprom -R .fuse -R .lock -R .signature \
    "$OUT.elf" "$OUT.hex"

echo ">> size:"
run avr-size "$OUT.elf"

if [ "$BUILD_ONLY" = 1 ]; then
    echo ">> build only; wrote $OUT.hex"
    exit 0
fi

# --- pick a port ----------------------------------------------------------
if [ -z "$PORT" ]; then
    CANDIDATES=()
    for d in /dev/ttyUSB* /dev/ttyACM*; do
        [ -e "$d" ] && CANDIDATES+=("$d")
    done
    if [ "${#CANDIDATES[@]}" -eq 0 ]; then
        echo "no /dev/ttyUSB* or /dev/ttyACM* found - pass -p PORT" >&2
        exit 1
    fi
    PORT="${CANDIDATES[0]}"
    echo ">> candidate serial ports: ${CANDIDATES[*]}"
    echo ">> using $PORT (pass -p to override; NB on the printer host"
    echo ">> /dev/ttyACM0 is the Smoothieboard, not the Nano)"
fi

# --- flash ----------------------------------------------------------------
flash_at() {
    local baud="$1"
    run avrdude -c arduino -p m328p -P "$PORT" -b "$baud" -D \
        -U "flash:w:$OUT.hex:i"
}

if [ -n "$BAUD" ]; then
    echo ">> flashing $OUT.hex to $PORT at $BAUD baud"
    flash_at "$BAUD"
else
    for b in 115200 57600; do
        echo ">> trying $PORT at $b baud"
        if flash_at "$b"; then
            echo ">> flashed at $b baud"
            exit 0
        fi
    done
    echo ">> upload failed at both 115200 and 57600 - is the Nano in reset?" >&2
    exit 1
fi

echo ">> done"
