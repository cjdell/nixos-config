#!/usr/bin/env bash
# flash-thread-rcp.sh — re-flash a Sonoff ZBDongle-P (TI CC2652P, marked "C2652P")
# from Zigbee coordinator firmware to OpenThread RCP (spinel) firmware, so the
# dongle can serve as the radio of a Thread border router.
#
# Run this ON THE MACHINE THE DONGLE IS PLUGGED INTO.
#
#   ./scripts/flash-thread-rcp.sh probe            # show what the port is
#   ./scripts/flash-thread-rcp.sh flash            # write ot_rcp firmware
#   PORT=/dev/ttyUSB1 ./scripts/flash-thread-rcp.sh flash
#
# Firmware: Koenkk/OpenThread-TexasInstruments-firmware 2025.3.1,
# CC1352P2_CC2652P_launchpad_ot_rcp — the image that repo lists explicitly for
# "SONOFF ZBDongle-P" (docs/adapters.md). This is the community Thread path:
# Sonoff's own flasher offers Zigbee-only for the CC2652P dongle.
# The flashed RCP speaks spinel over UART at 460800 8N1, no hardware flow
# control — that is what hosts/grafton-router/services/otbr.nix is configured
# for. Rollback = flash any Koenkk Z-Stack "CC1352P2_CC2652P_launchpad"
# coordinator hex back the same way.
#
# Background: docs/thread-border-router.md
set -euo pipefail

ZIP_URL="https://github.com/Koenkk/OpenThread-TexasInstruments-firmware/releases/download/2025.3.1/CC1352P2_CC2652P_launchpad_ot_rcp_2025_3_1.zip"
ZIP_SHA256="5858a338f4d82e11a269410a9917561e91a5130fe3d6207dfc7066b0ed9e7e1d"
HEX_SHA256="75330d9294629feb72d401a2ec73f8a886f822d1de2b74a513758e19494f7e9f"
HEX_NAME="CC1352P2_CC2652P_launchpad_ot_rcp_2025_3_1.hex"

PORT="${PORT:-/dev/ttyUSB0}"
WORKDIR="${WORKDIR:-/tmp/otbr-rcp-firmware}"

die() { echo "ERROR: $*" >&2; exit 1; }

probe() {
  [ -e "$PORT" ] || die "no such port $PORT (ls /dev/serial/by-id/ to find it; set PORT=...)"
  echo "port:   $PORT"
  udevadm info -q property -n "$PORT" 2>/dev/null | grep -E "ID_(VENDOR|MODEL|SERIAL|PATH)" || true
  # What has it open? (ZHA / zigbee Z2M local? must be stopped before flashing)
  if command -v fuser >/dev/null 2>&1; then
    sudo fuser "$PORT" 2>&1 || echo "port is free"
  fi
}

ensure_firmware() {
  mkdir -p "$WORKDIR"
  if [ ! -s "$WORKDIR/$HEX_NAME" ] || ! echo "$HEX_SHA256  $WORKDIR/$HEX_NAME" | sha256sum -c --status 2>/dev/null; then
    echo "downloading $ZIP_URL"
    timeout 60 curl -fsSL -o "$WORKDIR/rcp.zip" "$ZIP_URL"
    echo "$ZIP_SHA256  $WORKDIR/rcp.zip" | sha256sum -c - || die "zip sha256 mismatch"
    (cd "$WORKDIR" && unzip -o -q rcp.zip)
  fi
  echo "$HEX_SHA256  $WORKDIR/$HEX_NAME" | sha256sum -c - || die "hex sha256 mismatch"
  echo "firmware ok: $WORKDIR/$HEX_NAME"
}

flash() {
  probe
  ensure_firmware
  echo "flashing $HEX_NAME -> $PORT (enter BSL via Sonoff DTR/RTS pattern, erase+write+verify)"
  nix shell nixpkgs#cc2538-bsl --command \
    cc2538-bsl --bootloader-sonoff-usb -e -w -v -p "$PORT" "$WORKDIR/$HEX_NAME"
  echo
  echo "done. The dongle now presents as an OpenThread RCP (spinel UART)."
  echo "The port node may re-enumerate — re-check: ls -l /dev/serial/by-id/"
  echo "Host side: hosts/grafton-router/services/otbr.nix (docs/thread-border-router.md)"
}

case "${1:-}" in
  probe) probe ;;
  flash) flash ;;
  *) die "usage: $0 probe|flash   (env PORT=/dev/ttyUSBx overrides port)" ;;
esac
