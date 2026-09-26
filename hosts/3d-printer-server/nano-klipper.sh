#!/usr/bin/env bash
#
# nano-klipper -- build (and flash) Klipper AVR firmware for an Arduino Nano
# used as a *second* Klipper MCU on 3d-printer-server.
#
# WHY THIS EXISTS
# ---------------
# The Smoothieboard's thermistor channels read implausibly (docs/klipper-3d-printer.md
# section 6).  With a Nano in hand and no ADS1115, the clean fix is to run Klipper
# on the Nano as an extra micro-controller and put the two thermistors on its
# ADC pins -- the heater pins stay on the Smoothieboard.  Klipper supports
# atmega328p natively and has no restriction on a heater section whose
# sensor_pin lives on a different mcu than its heater_pin.
#
# NOTE: an ESP32 CANNOT be used for this -- upstream Klipper has no ESP32 port
# (see src/Kconfig: only AVR/ATSAM/ATSAMD/LPC176x/STM32/HC32F460/RP2040/...).
#
# Build + flash happen in the same `mkuf/klipper:<tag>-tools` image the
# Smoothieboard firmware tool uses; that image already carries
# avrdude/gcc-avr/binutils-avr/avr-libc (see Klipper's
# scripts/install-ubuntu-18.04.sh), so nothing extra is needed on the host.
#
# UNTESTED: written 2026-09-24 from Klipper's Kconfig/Makefile and modelled on
# the working hosts/3d-printer-server/klipper-firmware-update.sh.
# The first run should be `--build-only` to confirm the toolchain is present.
#
# Usage:
#   sudo ./nano-klipper.sh --build-only        # compile, show the hex
#   sudo ./nano-klipper.sh --flash             # build + avrdude onto the Nano
#   sudo ./nano-klipper.sh --flash -d /dev/ttyUSB0 -b 57600
#   sudo ./nano-klipper.sh --status
#
set -euo pipefail

PROG=nano-klipper

# Printer project checkout on this host (same one the Smoothieboard tool uses).
PRINTER_REPO=/home/cjdell/Projects/prind.delta

# Separate build config + output dir from the Smoothieboard build, so the two
# never clobber each other.
BUILD_CONFIG=config/build.nano.config
OUT_DIR=out-nano

# Nano clone (CH340) is normally /dev/ttyUSB0; /dev/ttyACM0 is the Smoothieboard.
DEFAULT_DEVICE=/dev/ttyUSB0

API=http://127.0.0.1

TAG=
DEVICE=$DEFAULT_DEVICE
BAUD=
DO_FLASH=0
DO_BUILD=1
DO_STATUS=0

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
$PROG -- build/flash Klipper firmware for an Arduino Nano (ATmega328P) as a 2nd MCU

Usage: sudo $PROG [options]

  -t, --tag TAG     Klipper version to build (default: the running klipper image)
  -r, --repo DIR    printer project checkout (default: $PRINTER_REPO)
  -d, --device DEV  Nano serial port (default: $DEFAULT_DEVICE)
  -b, --baud N      bootloader baud for avrdude (default: try 115200 then 57600)
      --flash       build, then flash the Nano with avrdude
      --build-only  build only (default if --flash is not given)
      --status      show the built hex and, if configured, the Nano MCU version

After the first flash, add the [mcu nano] section to printer.cfg (see
docs/klipper-3d-printer.md section 9.7) and *restart klipper* -- a new mcu
section needs a full host restart, not FIRMWARE_RESTART.
EOF
}

while (( $# )); do
  case $1 in
    -t|--tag)    TAG=$2; shift 2 ;;
    -r|--repo)   PRINTER_REPO=$2; shift 2 ;;
    -d|--device) DEVICE=$2; shift 2 ;;
    -b|--baud)   BAUD=$2; shift 2 ;;
    --flash)     DO_FLASH=1; shift ;;
    --build-only) DO_FLASH=0; shift ;;
    --status)    DO_STATUS=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

if (( EUID != 0 )); then
  log "not root - re-executing under sudo"
  exec sudo -- "$0" "$@"
fi

[[ -d $PRINTER_REPO ]] || die "printer project not found: $PRINTER_REPO"

CONFIG_ABS=$PRINTER_REPO/$BUILD_CONFIG
OUT_ABS=$PRINTER_REPO/$OUT_DIR
HEX=$OUT_ABS/klipper.elf.hex

# Version of the klipper image the running container was started from.
running_image_version() {
  local image
  image=$(podman inspect klipper --format '{{.Image}}' 2>/dev/null) || return 1
  [[ -n $image ]] || return 1
  podman image inspect "$image" \
    --format '{{index .Labels "org.prind.image.version"}}' 2>/dev/null || return 1
}

# Klipper reports the extra mcu as object "mcu nano".
nano_version() {
  curl -s --max-time 5 "$API/printer/objects/query?mcu%20nano" 2>/dev/null |
    jq -r '.result.status["mcu nano"].mcu_version // empty' 2>/dev/null || true
}

show_status() {
  local ver
  ver=$(nano_version)
  printf '%-20s %s\n' 'build config' "$CONFIG_ABS"
  printf '%-20s %s\n' 'build output' "$HEX"
  if [[ -s $HEX ]]; then
    printf '%-20s %s (%s bytes)\n' 'hex' 'present' "$(stat -c %s "$HEX")"
  else
    printf '%-20s %s\n' 'hex' '<not built>'
  fi
  printf '%-20s %s\n' 'nano MCU' "${ver:-<not configured / not running>}"
}

write_seed_config() {
  if [[ -s $CONFIG_ABS ]]; then
    log "using existing build config: $CONFIG_ABS"
    return
  fi
  log "writing build config seed: $CONFIG_ABS"
  mkdir -p "$(dirname "$CONFIG_ABS")"
  cat >"$CONFIG_ABS" <<'SEED'
# Klipper MCU firmware build config -- Arduino Nano / ATmega328P / UART0.
# The ATmega328P has only 32 KiB flash, so pinning the board alone and letting
# `make olddefconfig` enable every optional feature overflows the link.  This
# second MCU only does ADC (thermistors), so disable the rest explicitly.
CONFIG_MACH_AVR=y
CONFIG_MACH_atmega328p=y
CONFIG_AVR_FREQ_16000000=y
CONFIG_AVR_SERIAL_UART0=y
CONFIG_SERIAL_BAUD=250000
CONFIG_WANT_ADC=y
# CONFIG_WANT_SPI is not set
# CONFIG_WANT_SOFTWARE_SPI is not set
# CONFIG_WANT_I2C is not set
# CONFIG_WANT_SOFTWARE_I2C is not set
# CONFIG_WANT_HARD_PWM is not set
# CONFIG_WANT_BUTTONS is not set
# CONFIG_WANT_TMCUART is not set
# CONFIG_WANT_NEOPIXEL is not set
# CONFIG_WANT_PULSE_COUNTER is not set
# CONFIG_WANT_ST7920 is not set
# CONFIG_WANT_HD44780 is not set
# CONFIG_WANT_ADXL345 is not set
# CONFIG_WANT_LIS2DW is not set
# CONFIG_WANT_BMI160 is not set
# CONFIG_WANT_MPU9250 is not set
# CONFIG_WANT_ICM20948 is not set
# CONFIG_WANT_THERMOCOUPLE is not set
# CONFIG_WANT_HX71X is not set
# CONFIG_WANT_CS1237 is not set
# CONFIG_WANT_ADS131M0X is not set
# CONFIG_WANT_ADS1220 is not set
# CONFIG_WANT_LDC1612 is not set
# CONFIG_WANT_SENSOR_ANGLE is not set
# CONFIG_WANT_TRIGGER_ANALOG is not set
SEED
}

build_firmware() {
  local tools=$1 jobs
  jobs=$(nproc)
  if ! podman image exists "$tools"; then
    log "pulling $tools (large, one-off)"
    timeout 1800 podman pull "$tools"
  fi
  # Clean host-side (never `make clean`: $(OUT) is a bind-mount point).
  log "cleaning build dir $OUT_ABS"
  rm -rf "$OUT_ABS"
  mkdir -p "$OUT_ABS"
  log "building Nano (atmega328p, UART0, 250000) firmware from $tools"
  podman run --rm \
    --entrypoint /bin/bash \
    -v "$CONFIG_ABS:/opt/klipper/.config" \
    -v "$OUT_ABS:/opt/klipper/out" \
    -w /opt/klipper \
    "$tools" -c "make olddefconfig && make -j${jobs}"
  [[ -s $HEX ]] || die "build finished but $HEX is missing"
  log "built $HEX ($(stat -c %s "$HEX") bytes)"
}

flash_firmware() {
  local tools=$1 attempt
  log "flashing $HEX to $DEVICE"
  if [[ -n $BAUD ]]; then
    attempt=(avrdude -patmega328p -carduino -P"$DEVICE" -b"$BAUD" -D -U"flash:w:/opt/klipper/out/klipper.elf.hex:i")
    podman run --rm --privileged -v /dev:/dev \
      -v "$CONFIG_ABS:/opt/klipper/.config" -v "$OUT_ABS:/opt/klipper/out" \
      -w /opt/klipper "$tools" -c "${attempt[*]}"
    return
  fi
  # No baud given: try the modern optiboot rate first, then the old bootloader
  # (Klipper's `make flash` hardcodes avrdude's default = 115200).
  local bauds=(115200 57600)
  for attempt in "${bauds[@]}"; do
    log "trying $DEVICE at $attempt baud"
    if podman run --rm --privileged -v /dev:/dev \
        -v "$CONFIG_ABS:/opt/klipper/.config" -v "$OUT_ABS:/opt/klipper/out" \
        -w /opt/klipper "$tools" -c \
        "avrdude -patmega328p -carduino -P'$DEVICE' -b$attempt -D -Uflash:w:/opt/klipper/out/klipper.elf.hex:i"; then
      log "flashed at $attempt baud"
      return 0
    fi
  done
  die "avrdude failed at 115200 and 57600 - is the Nano in reset / on $DEVICE?"
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
  fi
fi
TOOLS_IMAGE="mkuf/klipper:${TAG}-tools"

log "target klipper version: $TAG"
log "tools image:            $TOOLS_IMAGE"
write_seed_config
build_firmware "$TOOLS_IMAGE"

if (( DO_FLASH )); then
  flash_firmware "$TOOLS_IMAGE"
  cat <<EOF

Flashed. Remaining steps (see docs/klipper-3d-printer.md section 9.7):
  1. wire the two NTC dividers to the Nano (A0 = extruder, A1 = bed)
  2. add [mcu nano] + sensor_pin: nano:PC0 / nano:PC1 to printer.cfg
  3. restart klipper (new mcu section -> full restart, not FIRMWARE_RESTART)
  4. verify:  sudo $PROG --status
EOF
else
  log "build only; flash with:  sudo $PROG --flash -d $DEVICE"
fi
