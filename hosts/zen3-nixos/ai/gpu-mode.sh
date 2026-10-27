# gpu-mode — hand zen3-nixos' R9700 (32 GiB) to exactly ONE thing at a time.
#
# Installed via ./gpu-mode.nix (writeShellScriptBin; PATH comes from there —
# systemctl, curl, amd-smi, coreutils, sed).
#
# A mode switch stops the previous owner first: a lease, not a hint. That is
# deliberate — with strata.service merely idle its auto-load would take the
# whole VRAM back on the next Pi/Recallium request mid-game, so sd/game mode
# STOP it. (Ad-hoc co-existence still works: ./sd-gate.nix evicts Strata's
# model over POST /v1/unload when SD needs the card, and Strata's before_load
# hook stops sd-gate back before reloading — whoever needed the GPU last wins
# it, nothing loops.)
#
# Mode changes run through sudo; wheel is passwordless on this box
# (common/system.nix), so gpu-mode never prompts.

set -u

SUDO=/run/setuid-programs/sudo
STATUS=http://127.0.0.1:8080/v1/status
CHAT=http://127.0.0.1:8080/v1/chat/completions
TOTAL_VRAM_MB=32624

usage() {
  cat <<'EOF'
gpu-mode — give the R9700 to exactly one thing at a time

  gpu-mode            who holds the card right now (default)
  gpu-mode llm        Strata / Qwen3.8-Flash-Next  (boot default: Pi sessions,
                      Recallium, strata.ai / llm.ai / 192.168.49.50 endpoints)
  gpu-mode sd         Stable Diffusion — sd-gate + web UI
                      http://192.168.49.50/sd/  (https://sd.ai.chrisdell.info)
  gpu-mode game       free the GPU for gaming  (aliases: free, off)

Modes are a lease: switching STOPS the previous owner, interrupting anything
mid-run (status shows what is in flight first, and llm/sd switches ask before
interrupting a live Strata turn when run interactively).

While sd/game mode is active the LLM endpoints are DOWN by design, so
background traffic cannot silently reload the 90 GB model into VRAM mid-game.
'gpu-mode llm' starts the engine again and waits until the model is loaded —
that load is multi-minute (~60 GiB of RAM; the box is sluggish while it runs).

A reboot always restores llm mode (strata.service is the only unit with
wantedBy; sd-gate is started by gpu-mode alone).
EOF
}

free_mib() {
  # amd-smi metric -m prints "free_vram": { "value": N, "unit": "MB" }
  amd-smi metric -m --json 2>/dev/null | tr -d ' \n' \
    | sed -n 's/.*"free_vram":{"value":\([0-9]*\).*/\1/p' | head -1
}

json_field() { # top-level key of /v1/status; prints nothing while Strata is down
  local j
  j=$(curl -s -m 5 "$STATUS" 2>/dev/null) || true
  [ -n "$j" ] || return 0
  printf '%s' "$j" | tr -d ' \n' | sed -n "s/.*\"$1\":\([A-Za-z0-9._-]*\)[,}].*/\1/p"
}

strata_loaded() { [ "$(json_field loaded)" = true ]; }

is_on() { systemctl is-active --quiet "$1"; }

wait_free() { # $1 = wanted free MiB, $2 = max seconds
  local want=$1 limit=$2 waited=0 got
  while :; do
    got=$(free_mib)
    [ -n "$got" ] || { echo "  (amd-smi did not answer; skipping the VRAM check)"; return 0; }
    [ "$got" -ge "$want" ] && { echo "  VRAM free: ${got} MiB of ${TOTAL_VRAM_MB}"; return 0; }
    if [ "$waited" -ge "$limit" ]; then
      echo "  VRAM free: ${got} MiB after ${limit}s — something still holds the card (check gpu-mode status)"
      return 1
    fi
    sleep 2
    waited=$((waited + 2))
  done
}

warn_llm_inflight() {
  local n ans
  n=$(json_field in_flight)
  [ -n "$n" ] && [ "$n" != 0 ] || return 0
  echo "warning: Strata has $n request(s) in flight — switching interrupts them." >&2
  if [ -t 0 ] && [ -t 1 ]; then
    printf 'continue? [y/N] '
    read -r ans
    case "$ans" in
      y | Y) ;;
      *)
        echo aborted
        exit 1
        ;;
    esac
  fi
}

mode_status() {
  local sa se f lease
  sa=$(systemctl is-active strata 2>/dev/null) || true
  se=$(systemctl is-active sd-gate 2>/dev/null) || true
  f=$(free_mib)
  lease="game — nothing holds the card (take it back: gpu-mode llm)"
  [ "$se" = active ] && [ "$sa" != active ] && lease="sd (Stable Diffusion)"
  [ "$sa" = active ] && lease="llm (Strata)"
  echo "R9700 lease : $lease"
  if [ "$sa" = active ]; then
    local ld fl
    ld=$(json_field loaded)
    fl=$(json_field in_flight)
    echo "  strata    : active — model loaded: ${ld:-not answering}, in flight: ${fl:-?}  (:8080)"
  else
    echo "  strata    : $sa"
  fi
  if [ "$se" = active ]; then
    echo "  sd-gate   : active — SDXL loads on the first request, UI: http://192.168.49.50/sd/"
  else
    echo "  sd-gate   : $se"
  fi
  echo "  VRAM      : ${f:-?} MiB free of ${TOTAL_VRAM_MB} MiB"
}

mode_llm() {
  local was waited=0
  was=$(systemctl is-active strata 2>/dev/null) || true
  echo "handing the R9700 to Strata (stopping sd-gate)..."
  $SUDO systemctl stop sd-gate
  $SUDO systemctl start strata
  # A serve layer that is already active with an UNLOADED engine (SD evicted
  # it) starts the model only on the next request: send a 1-token warm-up so
  # 'gpu-mode llm' really means "ready when this command returns".
  if [ "$was" = active ] && ! strata_loaded; then
    (curl -s -m 10 -o /dev/null -X POST -H 'Content-Type: application/json' \
      -d '{"messages":[{"role":"user","content":"ready"}],"max_tokens":1}' "$CHAT" 2>/dev/null) &
  fi
  echo "waiting for the model (multi-minute: ~60 GiB RAM + expert-cache fill)..."
  while :; do
    if strata_loaded; then
      echo "Strata ready — the LLM endpoints live again (:8080, /v1/chat/completions)."
      return 0
    fi
    if ! is_on strata; then
      echo "ERROR: strata.service is not active — journalctl -u strata" >&2
      return 1
    fi
    [ $((waited % 30)) -eq 0 ] && echo "  ${waited}s ... loaded: $(json_field loaded)"
    if [ "$waited" -ge 900 ]; then
      echo "still loading after 15 min — watch: journalctl -fu strata, /var/lib/strata/strata.log"
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
}

mode_sd() {
  warn_llm_inflight
  echo "handing the R9700 to Stable Diffusion (stopping Strata — LLM endpoints go down)..."
  $SUDO systemctl stop strata
  $SUDO systemctl start sd-gate
  wait_free 20000 60
  cat <<'EOF'
SD lease active.
  web UI : http://192.168.49.50/sd/   (https://sd.ai.chrisdell.info)
  API    : POST http://192.168.49.50/sd-api/sdapi/v1/txt2img
  state  : http://192.168.49.50/sd-status/
SDXL loads on the first request and unloads 120 s after the last one.
Pi / Recallium / strata.ai stay down until 'gpu-mode llm'.
EOF
}

mode_game() {
  warn_llm_inflight
  echo "freeing the R9700 (stopping Strata + sd-gate — anything mid-run is interrupted)..."
  $SUDO systemctl stop strata sd-gate
  wait_free 20000 60
  echo "the card is yours: 32 GiB of VRAM, plus the ~60 GiB of RAM Strata held."
  echo "gpu-mode llm gives it back to the AI stack; a reboot restores llm mode too."
}

cmd="${1:-status}"
case "$cmd" in
  llm) mode_llm ;;
  sd) mode_sd ;;
  game | free | off) mode_game ;;
  status) mode_status ;;
  help | --help | -h) usage ;;
  *)
    usage
    exit 2
    ;;
esac
