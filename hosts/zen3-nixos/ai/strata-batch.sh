#!/usr/bin/env bash
# strata-batch — serve two Strata conversations at once, on demand, or one
# alone at the full expert cache (the default).
#
#   strata-batch           status: current mode, what the engine actually runs,
#                          what a batch start cost
#   strata-batch on        restart strata with the batch run config
#                          ("parallel": 2 -> --batch 2), wait for the model
#                          load, verify concurrency.serving=2
#   strata-batch off       back to the solo config (the default)
#
# Installed via ./strata.nix (writeShellScriptBin; the PATH and sudo come from
# there — sudo is passwordless for wheel on this host, so strata-batch never
# prompts). The mode is one file, /var/lib/strata/batch-mode ("2" or "off",
# absent = off), and the unit's entry point re-reads it at EVERY start — so
# the choice survives reboots, `gpu-mode llm`, and rebuilds, and each rebuild
# points at fresh store paths (no stale-symlink trap).
#
# WHY a toggle and not just always-on batch (2026-11-10): the engine carves
# the batch slots' VRAM at STARTUP, "before the expert cache is sized, so
# --expert-cache auto leaves them room" (generate.cpp:6822), and there is no
# runtime re-allocation — BADM admits a conversation into an already-allocated
# slot; nothing ever hands VRAM back to the cache when the second stream goes
# away. So --batch 2 pays ~1.3 GiB of the ~24.5 GiB expert cache PERMANENTLY,
# even at idle. What IS already dynamic is the serving speed: even with batch
# mode on, a request running alone never enters a batch window — it runs the
# solo path at full draft speed (server.py:2230). This toggle is only about
# the reservation: pay it when you know you are about to run two sessions,
# not while nobody would.
#
# What a batch start gives on this box (Strata 0.2.13.1, verified against the
# pinned tree; full analysis + the numbers that changed since October:
# docs/strata-batching.md):
#   * two conversations decoding in one batch window, each with its OWN
#     DFlash2 drafter (the explicit --draft dflash2 + --batch pair turns
#     STRATA_BATCH_DF2 on; ~100 MiB of private ring+buffers per slot, the
#     pack is shared with the solo drafter);
#   * ~0.56 GiB of VRAM per slot session (--kv-resident 32768, int8 KV) plus
#     ~4.9 GiB of PINNED RAM per slot for the streamed whole-393K-ctx KV —
#     that last one is the number to watch here (94 GiB box, -cram OOM
#     history); `status` prints free RAM after every switch.
#   * the expert cache is ~5 % smaller, so a solo stream loses maybe a few
#     tenths of a hit-rate point and a few percent of tok/s for as long as
#     batch mode stays on. That is the trade.
#
# Failure handling — the box's LLM always comes back:
#   * the engine "recommends, never forces": if two slots do not fit it says
#     so and serves one; strata-batch reports that as serving=1 with the
#     engine's own line, it is not fatal.
#   * if a BATCH start does not reach loaded within the budget, or NRestarts
#     climbs (crash-loop), strata-batch rewrites the mode file to off,
#     restarts again, and reports what it did.
#   * `on`/`off` refuse while sd-server holds the card (gpu-mode sd lease) —
#     restarting strata there would evict Flux for streams nobody asked for.

set -uo pipefail

SUDO=/run/wrappers/bin/sudo
MODE=/var/lib/strata/batch-mode
S=http://127.0.0.1:8080
LOG=/var/lib/strata/strata.log
SLOT_WANT=2

status_json() { curl -s -m 5 "$S/v1/status" 2>/dev/null | tr -d ' \n' || true; }
field() { # field <compact-json> <key> — last occurrence wins ("serving" is nested once)
  printf '%s' "$1" | sed -n "s/.*\"$2\":\([A-Za-z0-9._-]*\)[,}].*/\1/p"
}
mode_now() { tr -d '[:space:]' < "$MODE" 2>/dev/null || true; }
nrestarts() { systemctl show strata -p NRestarts --value 2>/dev/null || echo 0; }

report() { # report — the shared status tail
  local j loaded serving
  j=$(status_json)
  loaded=$(field "$j" loaded); serving=$(field "$j" serving)
  echo "engine    : $(systemctl is-active strata 2>/dev/null)  loaded=${loaded:-no-answer}  concurrency.serving=${serving:-?}"
  if [ -s "$LOG" ]; then
    grep -a "batch-mode\|slot sessions take\|STRATA_BATCH_DF2\|batch_slots\|expert cache [0-9]* slots\|batch: 1 slot" "$LOG" 2>/dev/null | tail -4
    grep -a "decode expert cache hit rate" "$LOG" | tail -1
  fi
  echo "ram       : $(free -g | awk 'NR==2{print "used="$3"G  available="$7"G"} NR==3{print "swap : used="$3"G  free="$4"G"}' | tr '\n' ' ')"
}

wait_load() { # wait_load <nrestarts-baseline> — 0 = loaded, 1 = dead/crash-loop/timeout
  local base=$1 i j state loaded nr
  for i in $(seq 1 60); do    # 60 x 10s = 10 min; warm reload ~30 s, cold page cache minutes
    sleep 10
    j=$(status_json)
    state=$(systemctl is-active strata 2>/dev/null || true)
    loaded=$(field "$j" loaded)
    nr=$(nrestarts)
    echo "  [$i] state=$state loaded=${loaded:-?} restarts=$nr"
    [ "$loaded" = true ] && return 0
    [ "$state" = failed ] && return 1
    if [ "$nr" -gt "$base" ] 2>/dev/null; then echo "  NRestarts climbed — engine is crash-looping"; return 1; fi
  done
  return 1
}

set_mode() { # set_mode <2|off>
  printf '%s\n' "$1" | $SUDO tee "$MODE" >/dev/null && $SUDO chmod 644 "$MODE"
}

switch_to() { # switch_to <2|off>
  local want=$1 base j got
  if $SUDO systemctl is-active --quiet sd-server; then
    echo "refusing: gpu-mode lease is held by sd-server (Flux). gpu-mode llm first." >&2
    return 1
  fi
  base=$(nrestarts)
  set_mode "$want" || { echo "could not write $MODE" >&2; return 1; }
  echo "restarting strata with batch-mode=$want — model load ~30 s to a few minutes, LLM down meanwhile"
  $SUDO systemctl restart strata
  if ! wait_load "$base"; then
    if [ "$want" = "$SLOT_WANT" ]; then
      echo "the batch start did not come up — reverting to the solo config"
      set_mode off
      $SUDO systemctl restart strata
      if wait_load "$(nrestarts)"; then
        echo "RESULT=FAIL — batch refused to load; SOLO restored (grep 'batch\\|slot' $LOG)"
      else
        echo "RESULT=FAIL — strata will not load at all — journalctl -u strata -n 50"
      fi
      return 1
    fi
    echo "RESULT=FAIL — strata did not come up on the solo config either — journalctl -u strata -n 50"
    return 1
  fi
  j=$(status_json)
  got=$(field "$j" serving)
  if [ "$want" = "$SLOT_WANT" ]; then
    if [ "$got" = "$SLOT_WANT" ]; then
      echo "RESULT=OK — batch on: $SLOT_WANT slots. A lone request still runs the solo path at full speed;"
      echo "           the expert cache paid for the slots — see the lines above for the real bill."
    else
      echo "RESULT=PARTIAL — loaded but serving=${got:-?}, not $SLOT_WANT: the engine adjusted it down."
      grep -a "WARNING: --batch\|slot sessions fit\|not two slot sessions fit" "$LOG" | tail -2
      echo "           solo speed is intact (it never entered a window anyway); fix the fit or strata-batch off."
    fi
  else
    echo "RESULT=OK — batch off; full expert cache (serving=${got:-?})"
  fi
  report
}

case "${1:-status}" in
  status)
    m=$(mode_now)
    echo "mode file : ${m:-<absent>}  (= $( [ "$m" = "$SLOT_WANT" ] && echo batch || echo solo ))"
    $SUDO systemctl is-active --quiet sd-server && echo "note      : gpu-mode sd lease active — strata is stopped by design"
    report
    ;;
  on)
    m=$(mode_now)
    j=$(status_json)
    if [ "$m" = "$SLOT_WANT" ] && [ "$(field "$j" serving)" = "$SLOT_WANT" ] && [ "$(field "$j" loaded)" = true ]; then
      echo "already on — batch slots live, nothing to do"; report; exit 0
    fi
    switch_to "$SLOT_WANT"
    ;;
  off)
    m=$(mode_now)
    j=$(status_json)
    if [ "$m" != "$SLOT_WANT" ] && [ "$(field "$j" serving)" = 1 ] && [ "$(field "$j" loaded)" = true ]; then
      echo "already off — solo config live, nothing to do"; report; exit 0
    fi
    switch_to off
    ;;
  *)
    echo "usage: strata-batch [status|on|off]   (status is the default)" >&2
    exit 2
    ;;
esac
