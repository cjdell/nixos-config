#!/usr/bin/env bash
# hold-then-capture.sh — keep the card OUT for a real power-on reset, then make
# the userspace tool the first thing that touches it and try to capture.
#   ./hold-then-capture.sh [hold-secs] [input] [capture-secs]
set -u
cd "$(dirname "$0")"
HOLD="${1:-60}"; IN="${2:-composite1}"; SECS="${3:-6}"
LOG="logs/hold-$(date +%Y%m%d-%H%M%S).log"; mkdir -p logs
P="sudo -n ./pctv_probe"
say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
gone() { ! lsusb -d 2304: >/dev/null 2>&1; }

say "module loaded: $(lsmod | grep -c pctv320cx) (must be 0)"

if ! gone; then
  say "card is IN - pull it out now"
  for i in $(seq 1 240); do gone && break; sleep 0.5; done
  if ! gone; then say "still in after 120 s - giving up"; exit 1; fi
fi
say "card is OUT - holding ${HOLD} s so the slot rails actually drop. KEEP IT OUT."
for n in $(seq "$HOLD" -10 10); do say "  hold: ${n} s left - keep it OUT"; sleep 10; done
sleep 1
say "HOLD DONE. >>> INSERT THE CARD NOW <<<"
for i in $(seq 1 240); do ! gone && break; sleep 0.5; done
if gone; then say "card never came back - giving up"; exit 1; fi
say "card is IN: $(lsusb -d 2304: | tr -s ' ')"

say "FIRST accessor = pctv_probe GET_VERSION"
$P ver 2>&1 | tee -a "$LOG"
if grep -q "hw=" "$LOG"; then
  say "BRIDGE ALIVE at first touch"
else
  say "BRIDGE COLD at first touch -> cold start attempt (download + jumpram)"
  timeout 120 $P fw firmware/dvb-usb-dib0700-1.20.fw 2>&1 | tail -4 | tee -a "$LOG"
  sleep 1; $P ver 2>&1 | tee -a "$LOG"
  if ! grep -q "hw=" "$LOG"; then
    say "still cold -> try a USB port reset (re-runs the bridge ROM self-boot)"
    sudo -n ./pctv_probe reset 2>&1 | tee -a "$LOG"; sleep 2
    $P ver 2>&1 | tee -a "$LOG"
    if ! grep -q "hw=" "$LOG"; then
      say "COLD after power-on reset + download + port reset. No frames possible."
      exit 2
    fi
  fi
  say "BRIDGE ALIVE after cold start"
fi

say "userspace capture: $IN, ${SECS}s"
timeout 300 ./capture-live.sh "$IN" "$SECS" "hold" best 2>&1 | tee -a "$LOG"
say "done - log: $LOG"
