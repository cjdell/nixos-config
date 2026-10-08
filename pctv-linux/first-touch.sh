#!/usr/bin/env bash
# first-touch.sh — make the USERSPACE tool the very first accessor of the card
# after it enumerates, and capture frames from the userspace path.
#
# Why: every previous "cold card" measurement was taken after the pctv320cx
# kernel module had already probed the device (dmesg shows it auto-loaded by
# udev ~0.2 s after enumeration and run a full firmware download + jumpram).
# That download on a half-booted bridge is a prime suspect for the wedge.
# This script blocks that (see /etc/modprobe.d/99-pctv-test.conf) and then:
#
#   1. waits for the card to disappear (you pull it out)
#   2. waits for it to come back (you re-insert it)
#   3. GET_VERSION as the first vendor request, logged
#   4. if the bridge answers -> full analog bring-up + capture (capture-live.sh)
#      if it does not      -> one cold-start attempt (fw download + jumpram), logged
#
# Usage: ./first-touch.sh [input] [secs] [min-seconds-out]
set -u
cd "$(dirname "$0")"
IN="${1:-composite1}"; SECS="${2:-6}"; MINGONE="${3:-60}"
LOG="logs/first-touch-$(date +%Y%m%d-%H%M%S).log"
mkdir -p logs
P="sudo -n ./pctv_probe"

say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

say "kernel driver loaded? $(lsmod | grep -c pctv320cx) (must be 0)"
say "step 1: pull the ExpressCard out now, wait ~20 s, put it back"

# 1. wait for it to go away, then hold it away for MINGONE seconds so the
#    slot rails actually bleed down - a quick hot-swap does NOT power-cycle the
#    DiB0700 (the ExpressCard rail has enough capacitance to ride through it).
for i in $(seq 1 600); do
  lsusb -d 2304: >/dev/null 2>&1 || break
  sleep 0.5
done
if lsusb -d 2304: >/dev/null 2>&1; then say "still present after 300 s - giving up"; exit 1; fi
say "gone - keep it out ${MINGONE} s for a real power-on reset"
t0=$(date +%s)
while [ $(( $(date +%s) - t0 )) -lt "$MINGONE" ]; do
  if lsusb -d 2304: >/dev/null 2>&1; then say "back too early - put it back out for ${MINGONE} s"; 
    while lsusb -d 2304: >/dev/null 2>&1; do sleep 0.5; done
    t0=$(date +%s)
  fi
  sleep 1
done
say "held out $(( $(date +%s) - t0 )) s"

# 2. wait for it to come back
for i in $(seq 1 600); do
  lsusb -d 2304: >/dev/null 2>&1 && break
  sleep 0.5
done
if ! lsusb -d 2304: >/dev/null 2>&1; then say "did not come back - giving up"; exit 1; fi
say "present: $(lsusb -d 2304: | tr -s ' ')"

# 3. FIRST accessor: GET_VERSION
say "step 3: GET_VERSION (first vendor request after enumeration)"
$P ver 2>&1 | tee -a "$LOG"
if grep -q "hw=" "$LOG"; then
  say "BRIDGE ALIVE at first touch - the card self-boots; going straight to capture"
else
  say "BRIDGE COLD at first touch - one cold-start attempt (download + jumpram)"
  timeout 120 $P fw firmware/dvb-usb-dib0700-1.20.fw 2>&1 | tail -5 | tee -a "$LOG"
  sleep 1
  $P ver 2>&1 | tee -a "$LOG"
  if ! grep -q "hw=" "$LOG"; then
    say "cold start did not revive it - no frames possible; stopping"
  exit 2
  fi
  say "cold start WORKED - bridge is up"
fi

# 3b. last host-side lever: a USB port reset makes the bridge ROM re-run its
#     EEPROM self-boot. Cheap, and it is the only reset the slot offers.
say "step 3b: USB port reset, then GET_VERSION again"
sudo -n ./pctv_probe reset 2>&1 | tee -a "$LOG"
sleep 2
$P ver 2>&1 | tee -a "$LOG"
if ! grep -q "hw=" "$LOG"; then
  say "still cold after port reset - stopping"
  exit 3
fi

# 4. capture through the userspace path
say "step 4: userspace capture ($IN, ${SECS}s)"
timeout 300 ./capture-live.sh "$IN" "$SECS" "firsttouch" best 2>&1 | tee -a "$LOG"
say "done - log: $LOG"
