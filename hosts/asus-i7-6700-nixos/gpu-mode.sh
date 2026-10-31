# gpu-mode — hand this box's folding GPUs to exactly one thing at a time:
# the asus-i7-6700-nixos sibling of zen3-nixos' ai/gpu-mode.sh.
#
#   gpu-mode           who holds the cards right now (default)
#   gpu-mode fold      Folding@home on both cards + all 8 threads (boot default)
#   gpu-mode llm       llama.cpp on the GTX 1060, folding stopped meanwhile
#   gpu-mode off       nothing on the GPUs (aliases: free, game)
#
# Like zen3's, the lease is enforced by which units are RUNNING: switching
# STOPS the previous owner, and a reboot always restores fold (fah-client
# has wantedBy; llama-server.service deliberately has none — only gpu-mode
# starts it). Unlike zen3 the folding side is whole-client: FAH v8 keeps its
# settings in the SQLite DB (config.xml only seeds), so there is no
# per-GPU switch the script can trust — llm/off STOP fah-client.service
# outright. Work units in flight checkpoint and requeue; nothing breaks.
#
# fold restarts fah-client-configure (the module's fah-provision oneshot),
# which also re-enables the GPU slots and clears a Web Control pause — so
# `gpu-mode fold` recovers a hand-paused client too.
#
# Mode changes run through sudo; sudo is passwordless on this host.

set -u

SUDO=/run/wrappers/bin/sudo
API=http://127.0.0.1:8080
API_READY=http://192.168.49.65:8080/
BUS_1060=00000000:01:00.0 # nvidia-smi bus ids: 1060 = 01:00.0, 970 = 02:00.0
LEGACY_UNIT=llama-lfm3    # the transient systemd-run unit from the first manual run

usage() {
  cat <<'EOF'
gpu-mode — give the folding GPUs to exactly one thing at a time

  gpu-mode          who holds the cards right now (status)
  gpu-mode fold     Folding@home: both cards + all 8 threads (boot default)
  gpu-mode llm      llama.cpp (LFM3-1.7B-Q4_K_M) on the GTX 1060 —
                    http://192.168.49.65:8080/  (OpenAI API at /v1)
  gpu-mode off      free both cards  (aliases: free, game)

Modes are a lease: switching STOPS the previous owner, interrupting anything
mid-run (folding work units checkpoint and requeue). Interactive switches
ask first when FahCores are live. `gpu-mode fold` also clears a pause made
in Web Control (:7396).
EOF
}

fah_cores() { pgrep -c '^FahCore' 2>/dev/null || true; }

is_on() { systemctl is-active --quiet "$1"; }

llama_up() {
  [ "$(curl -s -o /dev/null -w '%{http_code}' -m 3 "$API/v1/models" 2>/dev/null)" = 200 ]
}

warn_folding() {
  local n ans
  n=$(fah_cores)
  [ "${n:-0}" != 0 ] || return 0
  echo "warning: $n folding core(s) mid-work-unit — stopping now checkpoints/requeues them." >&2
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

stop_llama() {
  $SUDO systemctl stop llama-server 2>/dev/null || true
  $SUDO systemctl stop "$LEGACY_UNIT" 2>/dev/null || true
}

cards() {
  nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total \
    --format=csv,noheader 2>/dev/null | while IFS=, read -r a b c d e; do
    echo "  GPU$a$b  util$c  mem$d / $e" | tr -s ' '
  done
  nvidia-smi --query-compute-apps=pid,gpu_bus_id,used_memory --format=csv,noheader 2>/dev/null |
    while IFS=, read -r pid bus mem; do
      local who
      who=$(ps -o comm= -p "${pid# }" 2>/dev/null || echo '?')
      bus=${bus# }
      [ "$bus" = "$BUS_1060" ] && echo "    on 1060: $who (pid ${pid# }, ${mem# })" ||
        echo "    on 970 : $who (pid ${pid# }, ${mem# })"
    done
}

mode_status() {
  local ls fs cores lease
  ls=$(systemctl is-active llama-server 2>/dev/null) || true
  fs=$(systemctl is-active fah-client 2>/dev/null) || true
  cores=$(fah_cores)
  lease='off — nothing holds the cards (gpu-mode fold | gpu-mode llm)'
  [ "$fs" = active ] && [ "${cores:-0}" = 0 ] && lease='fah-client is running but PAUSED — no folding cores (gpu-mode fold clears it)'
  [ "$fs" = active ] && [ "${cores:-0}" != 0 ] && lease="fold — Folding@home (${cores} cores)"
  [ "$ls" = active ] && lease='llm — llama.cpp on the GTX 1060'
  echo "GPU lease   : $lease"
  if [ "$ls" = active ]; then
    echo "  llama     : active — $API_READY (model id: LFM3-1.7B)"
  else
    echo "  llama     : $ls"
  fi
  if [ "$fs" = active ]; then
    if [ "${cores:-0}" = 0 ]; then
      echo '  fah-client: active — no folding cores (paused; gpu-mode fold clears it)'
    else
      echo "  fah-client: active — ${cores} folding core(s)"
    fi
  else
    echo "  fah-client: $fs"
  fi
  cards
}

mode_fold() {
  echo 'handing the cards back to Folding@home...'
  stop_llama
  is_on fah-client || $SUDO systemctl start fah-client
  local i
  for i in 1 2 3 4 5; do
    $SUDO systemctl restart fah-client-configure && break
    sleep 3
  done
  local waited=0
  while :; do
    [ "$(fah_cores)" != 0 ] && {
      echo "folding again:"
      cards
      echo 'Web Control: http://192.168.49.65:7396/'
      return 0
    }
    if [ "$waited" -ge 90 ]; then
      echo 'still no FahCores after 90 s — check: tail /var/lib/fah-client/log.txt' >&2
      return 1
    fi
    sleep 3
    waited=$((waited + 3))
  done
}

mode_llm() {
  warn_folding
  echo 'handing the GTX 1060 to llama.cpp (fah-client STOPPED — the CPU stops folding too)...'
  $SUDO systemctl stop fah-client
  stop_llama # the legacy transient unit would hold the VRAM otherwise
  $SUDO systemctl start llama-server
  local waited=0
  while :; do
    if llama_up; then break; fi
    if ! is_on llama-server; then
      echo 'ERROR: llama-server.service is not active — journalctl -u llama-server' >&2
      return 1
    fi
    if [ "$waited" -ge 120 ]; then
      echo 'the model did not come up within 2 min — journalctl -u llama-server' >&2
      return 1
    fi
    sleep 3
    waited=$((waited + 3))
  done
  # Verify it really landed on the 1060 (bus 01:00.0), not on whatever
  # Vulkan1 enumerates as after some driver update.
  local pid where
  pid=$(systemctl show -p MainPID --value llama-server)
  where=$(nvidia-smi --query-compute-apps=pid,gpu_bus_id --format=csv,noheader 2>/dev/null |
    awk -F, -v p="$pid" '$1 + 0 == p { gsub(/ /, "", $2); print $2 }')
  echo "llama.cpp ready — $API_READY (model id: LFM3-1.7B, OpenAI API at /v1/chat/completions)"
  if [ "$where" = "$BUS_1060" ]; then
    echo 'on the GTX 1060 (PCI 01:00.0) as intended.'
  else
    echo "warning: llama-server (pid $pid) is NOT on the 1060's bus (seen: ${where:-nowhere}) — check --device Vulkan1 against --list-devices" >&2
  fi
  echo 'the 970 goes idle with it; fah slots stay down until `gpu-mode fold`.'
}

mode_off() {
  warn_folding
  echo 'freeing both cards (folding + llama stopped)...'
  stop_llama
  $SUDO systemctl stop fah-client
  cards
  echo 'gpu-mode fold restores the boot state.'
}

cmd="${1:-status}"
case "$cmd" in
  fold) mode_fold ;;
  llm) mode_llm ;;
  off | free | game) mode_off ;;
  status) mode_status ;;
  help | --help | -h) usage ;;
  *)
    usage
    exit 2
    ;;
esac
