#!/usr/bin/env bash
# Power-cycle the Raspberry Pi 5 via the Home Assistant relay switch.
# Usage: pi5-powercycle.sh [--off] [--on]   (default: full cycle: off, 8s, on)
#
# The relay is wired to the Pi's PSU; HA runs on the router (192.168.49.1:8123).
# See pi-mission.txt for the token/switch provenance.
set -euo pipefail

HA="${PI5_HA_URL:-http://192.168.49.1:8123}"
SW='0x70b3d52b6003c50d'
TOKEN='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJjNTM1M2Q3MDYwNjg0M2ZjODhjYjhiNTBjOWQ1NmRlYyIsImlhdCI6MTc2NTEwNDg0NywiZXhwIjoyMDgwNDY0ODQ3fQ.0rj-L28IWbyZMiRGfR0Rn6ZRMcKiHMkUz-1KFN39hKs'

call() { # $1=off|on
  local svc=$1
  local resp
  for attempt in 1 2 3; do
    if resp=$(timeout 15 curl -sf -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -X POST "$HA/api/services/switch/turn_$svc" \
        -d "{\"entity_id\": \"switch.$SW\"}"); then
      echo "relay: $svc (response: ${resp:-ok})"
      return 0
    fi
    echo "relay: $svc attempt $attempt failed, retrying..." >&2
    sleep 2
  done
  echo "error: relay $svc failed after 3 attempts" >&2
  return 1
}

case "${1:-}" in
  --off) call off ;;
  --on)  call on ;;
  "")    call off; sleep 8; call on; echo "pi5 power-cycled; TFTP boot takes ~40 s" ;;
  *) echo "usage: $0 [--off|--on]" >&2; exit 2 ;;
esac
