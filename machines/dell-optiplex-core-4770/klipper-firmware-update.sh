#!/usr/bin/env bash
#
# klipper-firmware-update -- build (and optionally flash) the Klipper MCU
# firmware for the Smoothieboard on 3d-printer-server.
#
# Board:        Smoothieboard (LPC1768, 100 MHz, USB, 16KiB DFU bootloader)
# Printer cfg:  ~/Projects/prind.delta/config/printer.cfg
#               (derived from Klipper's config/generic-smoothieboard.cfg)
#
# WHY THIS EXISTS
# ---------------
# The klipper service runs mkuf/klipper:latest.  "latest" is explicitly a
# floating tag (see the upstream README: "may point to a new build within 24h"),
# and podman re-pulls it whenever the container is (re)started -- so the
# *host-side* Klipper version changes silently, while the firmware actually
# flashed into the MCU only changes when somebody runs this script.  As of
# 2026-09-24 the host was v0.13.0-770-gce7002bed while the MCU still ran a
# build from 2025-05-25 (~16 months of drift).
#
# So: this builds the MCU firmware from the *same* version the running
# container uses, derived from the image's org.prind.image.version label.
# Build both from the same tag and they can never drift apart.
#
# Run `--status` to see host vs MCU version at any time.
#
# BUILD CONFIG
# ------------
# Only the four board-selection symbols are pinned (see the seed written by
# this script); Klipper's `make olddefconfig` fills in everything else
# non-interactively.  16KiB bootloader offset is required for the
# triffid/LPC17xx-DFU-Bootloader that Smoothieboards ship with -- see
# Klipper's docs/Bootloaders.md, "LPC176x micro-controllers (Smoothieboards)".
#
# NOT USED ON PURPOSE: ~/Projects/prind.delta/config/build.config -- that file
# is an RP2040 build config left over from an unrelated build (its `out/board`
# symlink points at /opt/klipper/src/rp2040) and would produce firmware for the
# wrong MCU.
#
set -euo pipefail

PROG=klipper-firmware-update

# Printer project (mkuf/prind fork) checkout on this host.
PRINTER_REPO=/home/cjdell/Projects/prind.delta

# Our own build config + output dir (see "NOT USED ON PURPOSE" above).
BUILD_CONFIG=config/build.smoothieboard.config
OUT_DIR=out-smoothieboard

# Smoothieware / LPC17xx-DFU-Bootloader USB id.
DFU_DEVICE=1d50:6015

# Klipper API (nginx on :80 -> moonraker).
API=http://127.0.0.1

TAG=
DO_FLASH=0
DO_STATUS=0
TO_SD=

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
$PROG -- build/flash Klipper MCU firmware for the Smoothieboard (LPC1768)

Usage: sudo $PROG [options]

  -t, --tag TAG    Klipper version to build, e.g. v0.13.0-770-gce7002bed
                   (default: the version of the running klipper container)
  -r, --repo DIR   printer project checkout
                   (default: $PRINTER_REPO)
      --status     show host vs MCU firmware version and exit
      --flash      after building, flash over USB DFU. The board must be in
                   bootloader mode: hold PLAY, press+release RESET, release PLAY
      --to-sd DIR  after building, copy the firmware to DIR as firmware.bin
                   (SD-card flash method -- no bootloader mode needed)

Exactly one of --flash / --to-sd may be given; with neither, the script only
builds and prints instructions.

After flashing, Klipper must be restarted (FIRMWARE_RESTART) to reconnect to
the new firmware; --flash does this automatically.
EOF
}

while (( $# )); do
  case $1 in
    -t|--tag)
      [[ $# -ge 2 ]] || die "$1 needs an argument"
      TAG=$2
      shift 2
      ;;
    -r|--repo)
      [[ $# -ge 2 ]] || die "$1 needs an argument"
      PRINTER_REPO=$2
      shift 2
      ;;
    --to-sd)
      [[ $# -ge 2 ]] || die "$1 needs an argument"
      TO_SD=$2
      shift 2
      ;;
    --flash)
      DO_FLASH=1
      shift
      ;;
    --status)
      DO_STATUS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
done

if (( DO_FLASH )) && [[ -n $TO_SD ]]; then
  die "--flash and --to-sd are mutually exclusive"
fi

# podman here is rootful -> needs root. Re-exec so `PATH` set up by
# writeShellApplication survives (sudo would otherwise reset it).
if (( EUID != 0 )); then
  log "not root - re-executing under sudo"
  exec sudo -- "$0" "$@"
fi

[[ -d $PRINTER_REPO ]] || die "printer project not found: $PRINTER_REPO"

CONFIG_ABS=$PRINTER_REPO/$BUILD_CONFIG
OUT_ABS=$PRINTER_REPO/$OUT_DIR

api_get() {
  curl -s --max-time 5 "$API$1" 2>/dev/null || true
}

host_version() {
  api_get "/printer/info" | jq -r '.result.software_version // empty' 2>/dev/null || true
}

mcu_version() {
  api_get "/printer/objects/query?mcu" |
    jq -r '.result.status.mcu.mcu_version // empty' 2>/dev/null || true
}

# Version of the klipper image the running container was started from.
running_image_version() {
  local image
  image=$(podman inspect klipper --format '{{.Image}}' 2>/dev/null) || return 1
  [[ -n $image ]] || return 1
  podman image inspect "$image" \
    --format '{{index .Labels "org.prind.image.version"}}' 2>/dev/null || return 1
}

show_status() {
  local host mcu ver
  host=$(host_version)
  mcu=$(mcu_version)
  ver=$(running_image_version) || true
  printf '%-20s %s\n' 'container image' "${ver:-<klipper container not running>}"
  printf '%-20s %s\n' 'klipper host' "${host:-<klipper API not reachable>}"
  printf '%-20s %s\n' 'MCU firmware' "${mcu:-<unknown>}"
  printf '%-20s %s\n' 'build config' "$CONFIG_ABS"
  printf '%-20s %s\n' 'build output' "$OUT_ABS/klipper.bin"
}

write_seed_config() {
  if [[ -s $CONFIG_ABS ]]; then
    log "using existing build config: $CONFIG_ABS"
    return
  fi
  log "writing build config seed: $CONFIG_ABS"
  mkdir -p "$(dirname "$CONFIG_ABS")"
  cat >"$CONFIG_ABS" <<'SEED'
# Klipper MCU firmware build config -- Smoothieboard / LPC1768 / USB.
#
# Only the board selection is pinned; `make olddefconfig` fills in the rest
# (and rewrites this file with the full config on the first build).
CONFIG_MACH_LPC176X=y
CONFIG_MACH_LPC1768=y
CONFIG_LPC_FLASH_START_4000=y
CONFIG_LPC_USB=y
SEED
}

build_firmware() {
  local tools=$1
  mkdir -p "$OUT_ABS"
  if ! podman image exists "$tools"; then
    log "pulling $tools (large, one-off)"
    timeout 1800 podman pull "$tools"
  fi
  local jobs
  jobs=$(nproc)
  log "building firmware from $tools"
  # `make clean` first: Klipper's make does not reliably notice a changed
  # .config, and the output dir may hold artifacts from an earlier build.
  podman run --rm \
    --entrypoint /bin/bash \
    -v "$CONFIG_ABS:/opt/klipper/.config" \
    -v "$OUT_ABS:/opt/klipper/out" \
    -w /opt/klipper \
    "$tools" -c "make clean >/dev/null && make olddefconfig && make -j${jobs}"

  [[ -s $OUT_ABS/klipper.bin ]] ||
    die "build finished but $OUT_ABS/klipper.bin is missing"
  log "built $OUT_ABS/klipper.bin ($(stat -c %s "$OUT_ABS/klipper.bin") bytes)"
  sha256sum "$OUT_ABS/klipper.bin"
}

flash_firmware() {
  local tools=$1
  log "flashing over DFU ($DFU_DEVICE)"
  warn "board must be in bootloader mode: hold PLAY, press+release RESET, release PLAY"
  if ! podman run --rm --privileged \
    -v /dev:/dev \
    -v "$CONFIG_ABS:/opt/klipper/.config" \
    -v "$OUT_ABS:/opt/klipper/out" \
    -w /opt/klipper \
    --entrypoint /bin/bash \
    "$tools" -c "make flash FLASH_DEVICE=$DFU_DEVICE"; then
    warn "DFU flash failed"
    warn "if the board was not in bootloader mode, retry; otherwise build to SD (--to-sd DIR)"
    return 1
  fi
}

copy_to_sd() {
  [[ -d $TO_SD ]] || die "not a directory: $TO_SD"
  log "copying firmware to $TO_SD/firmware.bin"
  cp -v "$OUT_ABS/klipper.bin" "$TO_SD/firmware.bin"
}

restart_klipper() {
  log "requesting FIRMWARE_RESTART"
  curl -s --max-time 10 -X POST \
    "$API/printer/gcode/script?script=FIRMWARE_RESTART" >/dev/null ||
    warn "FIRMWARE_RESTART request failed - use the Mainsail UI"
}

if (( DO_STATUS )); then
  show_status
  exit 0
fi

if [[ -z $TAG ]]; then
  TAG=$(running_image_version) || true
  if [[ -z ${TAG:-} ]]; then
    TAG=latest
    warn "klipper container not running - falling back to the floating 'latest' tag"
    warn "start the container first if you want the firmware to match the host"
  fi
fi

TOOLS_IMAGE="mkuf/klipper:${TAG}-tools"

log "target klipper version: $TAG"
log "tools image:            $TOOLS_IMAGE"
write_seed_config
build_firmware "$TOOLS_IMAGE"

if (( DO_FLASH )); then
  if flash_firmware "$TOOLS_IMAGE"; then
    restart_klipper
    log "done - check with: $PROG --status"
  else
    die "flash failed - nothing was restarted"
  fi
elif [[ -n $TO_SD ]]; then
  copy_to_sd
  cat <<EOF

Now, to flash via SD card:
  1. unmount the SD card and put it back in the Smoothieboard
  2. power-cycle the printer (the bootloader flashes firmware.bin on boot)
  3. restart the firmware from Mainsail, or:

       curl -X POST $API/printer/gcode/script?script=FIRMWARE_RESTART

  4. verify:  $PROG --status
EOF
else
  cat <<EOF

Built. Now flash it, either:

  SD card (easiest, no bootloader mode needed):
    sudo $PROG --to-sd /run/media/\$USER/<card>
    then power-cycle the printer with the card in

  USB DFU (no card swap):
    hold PLAY, press+release RESET, release PLAY
    sudo $PROG --flash

Then restart the firmware and verify with:  $PROG --status
EOF
fi
