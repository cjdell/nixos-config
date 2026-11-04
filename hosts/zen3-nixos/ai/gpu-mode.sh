# gpu-mode — hand zen3-nixos' R9700 (32 GiB) to exactly ONE thing at a time.
#
# Installed via ./gpu-mode.nix (writeShellScriptBin; PATH comes from there —
# systemctl, curl, amd-smi, coreutils, sed).
#
# A mode switch stops the previous owner first: a lease, not a hint. That is
# deliberate — with avalon.service merely idle, its :8080 would keep taking
# Pi/Recallium requests mid-game, and a stopped-but-reloadable engine would
# hand the whole VRAM back on the next request, so sd/game mode STOP it.
# Unlike Strata, llama.cpp's server has NO unload endpoint (the model lives
# for the process lifetime), so unit state is the whole lease: 'gpu-mode sd'
# is also how SD gets the card off the LLM (sd-gate's old cooperative
# POST /v1/unload is gone; an ad-hoc overlap just runs SD at GTT-spill
# speed). See ./sd-gate.nix.
#
# Mode changes run through sudo; wheel is passwordless on this box
# (common/system.nix), so gpu-mode never prompts.

set -u

SUDO=/run/wrappers/bin/sudo
HEALTH=http://127.0.0.1:8080/health
SLOTS=http://127.0.0.1:8080/slots
TOTAL_VRAM_MB=32624

usage() {
  cat <<'EOF'
gpu-mode — give the R9700 to exactly one thing at a time

  gpu-mode            who holds the card right now (default)
  gpu-mode llm        Avalon / Qwen3.8-Flash-Next  (boot default: Pi sessions,
                      Recallium, strata.ai / llm.ai / 192.168.49.50 endpoints)
  gpu-mode sd         Stable Diffusion — sd-gate + web UI
                      http://192.168.49.50/sd/  (https://sd.ai.chrisdell.info)
  gpu-mode game       free the GPU for gaming  (aliases: free, off)

Modes are a lease: switching STOPS the previous owner, interrupting anything
mid-run (status shows what is in flight first, and llm/sd switches ask before
interrupting a live turn when run interactively).

While sd/game mode is active the LLM endpoints are DOWN by design — llama.cpp
has no unload endpoint, so only stopping avalon.service really frees the
card. 'gpu-mode llm' starts it again and waits until /health reports ready;
the model load is mmap of ~89 GiB plus the expert-cache fill from
moe-cache-ranking.bin (minutes on a cold page cache, faster warm).

A reboot always restores llm mode (avalon.service is the only unit with
wantedBy; sd-gate is started by gpu-mode alone).
EOF
}

free_mib() {
  # amd-smi metric -m prints "free_vram": { "value": N, "unit": "MB" }
  amd-smi metric -m --json 2>/dev/null | tr -d ' \n' \
    | sed -n 's/.*"free_vram":{"value":\([0-9]*\).*/\1/p' | head -1
}

healthy() {
  # llama-server answers /health with 503 while the model is still loading
  # and with {"status":"ok"} once it serves; curl -f fails on both non-2xx
  # and connection refused.
  curl -sf -m 5 "$HEALTH" >/dev/null 2>&1
}

in_flight() {
  # GET /slots (enabled by --slots in ./avalon.nix): one object per slot with
  # "is_processing":true while it works. Prints 0 when the server is down or
  # the endpoint is absent, so callers never mis-warn.
  local j
  j=$(curl -s -m 5 "$SLOTS" 2>/dev/null) || { echo 0; return; }
  printf '%s' "$j" | tr -d ' ' | grep -o '"is_processing":true' | wc -l | tr -d ' '
}

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
  n=$(in_flight)
  [ -n "$n" ] && [ "$n" != 0 ] || return 0
  echo "warning: Avalon has $n request(s) in flight — switching interrupts them." >&2
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
  local av se f lease
  av=$(systemctl is-active avalon 2>/dev/null) || true
  se=$(systemctl is-active sd-gate 2>/dev/null) || true
  f=$(free_mib)
  lease="game — nothing holds the card (take it back: gpu-mode llm)"
  [ "$se" = active ] && [ "$av" != active ] && lease="sd (Stable Diffusion)"
  [ "$av" = active ] && lease="llm (Avalon)"
  echo "R9700 lease : $lease"
  if [ "$av" = active ]; then
    if healthy; then
      echo "  avalon    : active — model ready, in flight: $(in_flight)  (:8080)"
    else
      echo "  avalon    : active — model still loading (or not answering)  (:8080)"
    fi
  else
    echo "  avalon    : $av"
  fi
  if [ "$se" = active ]; then
    echo "  sd-gate   : active — SDXL loads on the first request, UI: http://192.168.49.50/sd/"
  else
    echo "  sd-gate   : $se"
  fi
  echo "  VRAM      : ${f:-?} MiB free of ${TOTAL_VRAM_MB} MiB"
}

mode_llm() {
  echo "handing the R9700 to Avalon (stopping sd-gate)..."
  $SUDO systemctl stop sd-gate
  $SUDO systemctl start avalon
  local waited=0
  echo "waiting for the model (mmap ~89 GiB + expert-cache fill)..."
  while :; do
    if healthy; then
      echo "Avalon ready — the LLM endpoints live again (:8080, /v1/chat/completions)."
      return 0
    fi
    if ! is_on avalon; then
      echo "ERROR: avalon.service is not active — journalctl -u avalon" >&2
      return 1
    fi
    [ $((waited % 30)) -eq 0 ] && echo "  ${waited}s ..."
    if [ "$waited" -ge 900 ]; then
      echo "still loading after 15 min — watch: journalctl -fu avalon"
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
}

mode_sd() {
  warn_llm_inflight
  echo "handing the R9700 to Stable Diffusion (stopping Avalon — LLM endpoints go down)..."
  $SUDO systemctl stop avalon
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
  echo "freeing the R9700 (stopping Avalon + sd-gate — anything mid-run is interrupted)..."
  $SUDO systemctl stop avalon sd-gate
  wait_free 20000 60
  echo "the card is yours: 32 GiB of VRAM back (Avalon's model pages live in the"
  echo "reclaimable page cache, so RAM comes back under pressure on its own)."
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
