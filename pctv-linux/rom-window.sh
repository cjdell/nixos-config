#!/usr/bin/env bash
# rom-window.sh - drive pctv_probe's ROM / EEPROM window catchers.
#
# Usage:
#   ./rom-window.sh [SECS] [--dir DIR] [--no-fw] [--fw FILE]
#                   [--reset-every N] [--max N] [--eeprom] [--map] [--hold] [--quiet]
#
#   SECS            how long to watch (default 1800 = 30 min)
#   --dir DIR       output directory (default logs/<mode>-<epoch>)
#   --no-fw         do not send the RAM firmware download as a provocation
#   --fw FILE       firmware image to download (default firmware/win_fw.bin)
#   --reset-every N USB port reset every N iterations (default: never)
#   --max N         stop after N captured windows (default: until SECS)
#   --eeprom        watch for the GET_EEPROM read service instead of the ROM
#                   window (`pctv_probe eepromwin`): grabs the whole 256-byte
#                   image + the index-form map the moment request 0x02 answers
#   --map           include the vendor-request map in each ROM window snapshot.
#                   DESTRUCTIVE: rq 0x02 with wValue 0 wedges the ROM's I2C
#                   engine, i.e. it kills the EEPROM read service (default off)
#   --hold          print pull/re-plug instructions and expect you to do it
#   --quiet         suppress progress lines
#
# This is READ-ONLY against the device's persistent storage: it only reads the
# config EEPROM, GET_VERSION and GET_GPIO, plus the ordinary non-persistent RAM
# firmware download. It never writes the EEPROM.
#
# Full interpretation guide: ./ROM-WINDOW.md
set -euo pipefail

cd "$(dirname "$0")"
HERE=$PWD
PROBE="$HERE/pctv_probe"
VIDPID=2304:022e

SECS=1800
DIR=""
MODE=romwin
FW_ARGS=(--fw "$HERE/firmware/win_fw.bin")
EXTRA=()
HOLD=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)          DIR=${2:?--dir needs an argument}; shift 2;;
    --no-fw)        FW_ARGS=(--no-fw); shift;;
    --fw)           FW_ARGS=(--fw "${2:?--fw needs an argument}"); shift 2;;
    --reset-every)  EXTRA+=(--reset-every "${2:?}"); shift 2;;
    --max)          EXTRA+=(--max "${2:?}"); shift 2;;
    --map)          EXTRA+=(--map); shift;;
    --eeprom)       MODE=eepromwin; shift;;
    --quiet)        EXTRA+=(--quiet); shift;;
    --hold)         HOLD=1; shift;;
    -h|--help)      sed -n '2,33p' "$0"; exit 0;;
    [0-9]*)         SECS=$1; shift;;
    *)              echo "unknown argument: $1" >&2; exit 2;;
  esac
done
LOG=romwin.log
[ "$MODE" = eepromwin ] && LOG=watch.log

if [ ! -x "$PROBE" ]; then
  echo "ERROR: $PROBE is missing or not executable. Build it with:" >&2
  echo "  (cd $HERE && ./build.sh)" >&2
  exit 1
fi

if [ -z "$DIR" ]; then
  DIR="$HERE/logs/$MODE-$(date +%s)"
fi
mkdir -p "$DIR"

# ---------------------------------------------------------------- preflight --
echo "== rom-window: preflight =="

if lsusb -d "$VIDPID" >/dev/null 2>&1; then
  echo "  device        : present ($VIDPID)"
else
  echo "  device        : NOT enumerated right now"
  echo "                  ($MODE waits for it; if the win7 VM holds it, detach first:"
  echo "                   virsh -c qemu:///system detach-device win7 /tmp/pctv-hostdev-vidpid.xml --live )"
fi

LOADED=$(lsmod 2>/dev/null | grep -oE '^(pctv320cx|dvb_usb_dib0700)' | head -1 || true)
if [ -n "$LOADED" ]; then
  echo "  kernel driver : LOADED ($LOADED) - it will re-claim the card on hot-plug"
  echo "                  unloading now (reversible)..."
  sudo rmmod pctv320cx dvb_usb_dib0700 2>/dev/null || true
  if lsmod 2>/dev/null | grep -qE '^pctv320cx'; then
    echo "                  still loaded - block it (recipe in HANDOVER.md, 2026-10-08 14:20):"
    echo "                    echo \"install pctv320cx \$(command -v false)\" | sudo tee /etc/modprobe.d/99-pctv-test.conf"
  else
    echo "                  unloaded"
  fi
else
  echo "  kernel driver : not loaded (good)"
fi

if [ "$HOLD" = 1 ]; then
  cat <<'EOF'
  --hold mode:
    1. Pull the ExpressCard out NOW and keep it out for >= 60 s.
       (A short hot-swap does not drop the slot rails - see HANDOVER §0.)
    2. Re-insert it while this script is running.
    The watcher will catch whatever the card does first.
  NOTE: a pull is exactly what restores the GET_EEPROM (I2C) read service, so
  for --eeprom a pull is not optional - the service is wedged until then.
EOF
fi

echo "  output dir    : $DIR"
echo

# --------------------------------------------------------------- dmesg base --
sudo dmesg > "$DIR/dmesg-before.txt" 2>/dev/null || true
BEFORE_LINES=$(sudo dmesg 2>/dev/null | wc -l || echo 0)

# ------------------------------------------------------------------- run it --
echo "== rom-window: watching for $SECS s ($MODE) =="
set +e
sudo "$PROBE" "$MODE" "$SECS" "$DIR" "${FW_ARGS[@]}" "${EXTRA[@]}" 2>&1 \
  | tee "$DIR/$LOG"
RC=${PIPESTATUS[0]}
set -e

# ------------------------------------------------------------- dmesg after --
sudo dmesg > "$DIR/dmesg-after.txt" 2>/dev/null || true
sudo dmesg 2>/dev/null | tail -n +"$((BEFORE_LINES + 1))" > "$DIR/dmesg-during.txt" || true

# ------------------------------------------------------------------ summary --
WINDOWS=$(grep -c "ROM WINDOW #\|EEPROM WINDOW at" "$DIR/$LOG" 2>/dev/null || true)
echo
echo "== rom-window: summary =="
echo "  mode          : $MODE"
echo "  pctv_probe exit : $RC"
echo "  windows caught  : ${WINDOWS:-0}"
if [ "${WINDOWS:-0}" -gt 0 ] 2>/dev/null; then
  echo
  echo "  --- GET_VERSION seen in windows ---"
  grep -h "GET_VERSION\|hw=0x" "$DIR/$LOG" | head -8 || true
  if [ "$MODE" = eepromwin ]; then
    echo
    echo "  --- EEPROM image (first window) ---"
    sed -n '/EEPROM WINDOW at/,/wrap check/p' "$DIR/$LOG" | head -40
    echo
    echo "  --- index/value form map ---"
    sed -n '/GET_EEPROM form map/,/recip0/p' "$DIR/$LOG" | head -90
  fi
fi
echo
echo "  files in $DIR:"
ls -la "$DIR" 2>/dev/null || true

echo
echo "Next: read $HERE/ROM-WINDOW.md for how to interpret the dump."
[ "${WINDOWS:-0}" -gt 0 ] 2>/dev/null && exit 0 || exit 1
