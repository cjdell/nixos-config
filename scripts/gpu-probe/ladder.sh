#!/usr/bin/env bash
# gpu-probe ladder — selective GPU stress, one workload axis per step.
#
# Why this shape: a card that dies under CUDA compute but loves Furmark, or one
# that logs AER Physical-Layer errors but passes a GL loop, can only be pinned
# down by varying ONE axis at a time and watching which step kills it. Each step
# is a step function in: engine (SM / copy engine / GDDR5 / idle context),
# user-mode runtime (CUDA driver API vs OpenCL ICD), launch shape (churn vs
# continuous), concurrency (GPU alone vs GPU + CPU threads), and link speed.
#
# A confirmed kill usually needs a reboot to reclaim the bus (the card drops off
# while often driving the console, and a core wedged in a driver ioctl is
# SIGKILL-proof), so the runner is a per-boot state machine:
#   verdict -> results.log -> reboot -> resume at the next step.
# Every path terminates; `ABORT` in the state dir stops it, `--no-reboot` stops
# the machine from rebooting at all.
#
# Usage: gpu-probe-ladder [options]            (see --help)
set -u

TOOL_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/gpu-probe
STEPS=$TOOL_DIR/steps/default.tsv
LINK=keep
PLIMIT=keep
ONLY=
MAX_REBOOTS=14
REBOOT=1
DRY=0
PROBE_ARGS=

help() { sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }
while [ $# -gt 0 ]; do
  case "$1" in
    --state-dir) STATE_DIR=$2; shift 2;;
    --steps) STEPS=$2; shift 2;;    --link) LINK=$2; shift 2;;
    --power-limit) PLIMIT=$2; shift 2;;
    --only) ONLY=$2; shift 2;;
    --gpu) PROBE_ARGS="$PROBE_ARGS --gpu $2"; shift 2;;
    --max-reboots) MAX_REBOOTS=$2; shift 2;;
    --no-reboot) REBOOT=0; shift;;
    --dry-run) DRY=1; shift;;
    --reset) rm -f "$STATE_DIR/state" "$STATE_DIR/reboot-count"; shift;;
    --help|-h) help;;
    *) echo "unknown arg: $1 (try --help)" >&2; exit 2;;
  esac
done
case "$LINK" in gen3) LTGT=3;; gen1) LTGT=1;; keep|*) LTGT=;; esac
# --steps accepts a bare table name: --steps xid79 -> <tool>/steps/xid79.tsv
case "$STEPS" in
  /*|./*) ;;
  *) [ -f "$STEPS" ] || STEPS=$TOOL_DIR/steps/$STEPS.tsv ;;
esac
[ -r "$STEPS" ] || { echo "no step table: $STEPS" >&2; exit 2; }

mkdir -p "$STATE_DIR/runs"
cd "$STATE_DIR" || exit 3
RESULTS=$STATE_DIR/results.log
touch state reboot-count
[ -s state ] || echo 1 > state
[ -s reboot-count ] || echo 0 > reboot-count
SMI=$(command -v nvidia-smi || ls /nix/store/*-nvidia-x11-*-bin/bin/nvidia-smi 2>/dev/null | head -1)
PROBE=${GPU_PROBE_PY:-"$(command -v python3 || ls /nix/store/*-python3-3*/bin/python3 2>/dev/null | grep -v -- -env | head -1) $TOOL_DIR/probe.py"}
export PROBE

log() { echo "$(date -Is) $*" | tee -a "$RESULTS"; }
gpu_bdf() { for d in /sys/bus/pci/devices/*; do [ -r "$d/class" ] || continue
    [ "$(cat $d/vendor 2>/dev/null)" = "0x10de" ] || continue
    case "$(cat $d/class 2>/dev/null)" in 0x030000|0x030200) basename "$d"; return;; esac
  done; }
root_port_of() { local b=$1; [ -n "$b" ] && basename "$(dirname "$(readlink -f /sys/bus/pci/devices/$b)")"; }
link_now() { local b=${1:-$(gpu_bdf)}
  if [ -n "$b" ]; then
    echo "$(cat /sys/bus/pci/devices/$b/current_link_speed 2>/dev/null || echo GONE) x$(cat /sys/bus/pci/devices/$b/current_link_width 2>/dev/null || echo ?)"
  else echo "no-nvidia-gpu"; fi; }
card_alive() { [ -n "$SMI" ] && timeout 15 "$SMI" --query-gpu=name --format=csv,noheader >/dev/null 2>&1; }
gpu_state() { local b=$(gpu_bdf); echo "${b:-none} $(link_now "$b")"; }
# Physical-Layer faults show up as the link renegotiating under load, so sample
# the link every tick (not once per step) and count transitions per step.
# energy_uj is root-readable on most boards: fall back to sudo -n, and once it is
# clear that it will never work, stop spawning sudo every 2 s (the flag lives in
# the sampling loop, not in this subshell).
RAPL_OK=1
cpu_uj() { local v="" f
  for f in /sys/class/powercap/intel-rapl:0/energy_uj /sys/class/powercap/intel-rapl:0:0/energy_uj; do
    [ -e "$f" ] || continue
    v=$(cat "$f" 2>/dev/null || true)
    [ -n "$v" ] || v=$(sudo -n cat "$f" 2>/dev/null || true)
    [ -n "$v" ] && { echo "$v"; return; }
  done
  echo NA; }
cpu_mC() { for h in /sys/class/hwmon/hwmon*; do
    [ "$(cat $h/name 2>/dev/null)" = coretemp ] && { cat $h/temp1_input 2>/dev/null; return; }; done; echo NA; }
die_marker() { timeout 30 journalctl -k --no-pager --since "@$1" 2>/dev/null \
  | grep -m3 -E 'Xid \(PCI:[0-9a-f:]+\): (79|154)|fallen off the bus|AER:.*[Ff]atal|AER: Uncorrectable|CmpltTO|RxErr|BadDLLP' \
  | sed 's/^.*kernel: //' | tr '\n' ' | '; }

sample() { local out=$1 prev="" trans=0
  echo "epoch,gpu_W,gpu_limit_W,gpu_sm_MHz,gpu_mem_MHz,gpu_C,throttle,util,memused,link,cpu_uj,cpu_mC" > "$out"
  while :; do
    local q lk
    if [ -n "$SMI" ]; then
      q=$(timeout 8 "$SMI" --query-gpu=power.draw,power.limit,clocks.sm,clocks.mem,temperature.gpu,clocks_throttle_reasons.active,utilization.gpu,memory.used --format=csv,noheader,nounits 2>/dev/null)
      [ -n "$q" ] || q="ERR,ERR,ERR,ERR,ERR,ERR,ERR,ERR"
    else q="n/a,n/a,n/a,n/a,n/a,n/a,n/a,n/a"; fi
    lk=$(link_now)
    [ -n "$prev" ] && [ "$prev" != "$lk" ] && trans=$((trans+1))
    prev=$lk; echo "$trans" > "$out.transitions"
    if [ "$RAPL_OK" = 1 ]; then uj=$(cpu_uj); [ "$uj" = NA ] && RAPL_OK=0; else uj=NA; fi
    cm=$(cpu_mC)
    echo "$(date +%s),${q// /},${lk// /},$uj,$cm" >> "$out"
    sleep 2
  done; }

# --- preamble: fix the operating point so boots are comparable, and record drift
BOOT=$(cat /proc/sys/kernel/random/boot_id)
log "BOOT id=$BOOT resume-at=$(cat state) gpu=$(gpu_state)"
[ -e ABORT ] && { log "ABORT present, exiting"; exit 0; }
if [ -e mask-fah ]; then
  sudo -n systemctl stop fah-client >/dev/null 2>&1
  sudo -n systemctl mask --runtime fah-client >/dev/null 2>&1
  # ... and the peak-hours pause timer, which would otherwise pause (or resume)
  # folding underneath the one step that is supposed to be the real control.
  sudo -n systemctl stop fah-pause-window.timer fah-pause-window.service >/dev/null 2>&1
  log "fah-client stopped + runtime-masked, pause-window timer stopped (mask-fah marker present)"
fi

# Optional tools some steps need; a step whose tool is absent is skipped, not
# counted as a result.
STRESS=$(command -v stress-ng || true)
HASHCAT=$(command -v hashcat || true)
export STRESS HASHCAT

if [ -n "$SMI" ]; then
  sudo -n timeout 20 "$SMI" -pm 1 >/dev/null 2>&1
  if [ "$PLIMIT" != keep ]; then
    sudo -n timeout 20 "$SMI" -pl "$PLIMIT" >/dev/null 2>&1
    now=$(timeout 15 "$SMI" --query-gpu=power.limit --format=csv,noheader,nounits 2>/dev/null)
    log "power-limit requested=${PLIMIT}W holds=${now}W $([ "${now%.*}" = "$PLIMIT" ] && echo OK || echo DRIFTED-some-other-unit-is-setting-it)"
  fi
  log "operating point: $(timeout 15 "$SMI" --query-gpu=name,power.limit,clocks.sm,memory.total --format=csv,noheader 2>&1 | tr -d '\n')"
fi
if [ -n "$LTGT" ]; then
  RP=$(root_port_of "$(gpu_bdf)")
  for try in 1 2 3; do
    cur=$(sudo -n setpci -s $RP CAP_EXP+0x30.w 2>/dev/null) || break
    sudo -n setpci -s $RP CAP_EXP+0x30.w=$(printf '%04x' $(( (0x$cur & ~0xf) | LTGT ))) 2>/dev/null
    cur=$(sudo -n setpci -s $RP CAP_EXP+0x10.w 2>/dev/null) || break
    sudo -n setpci -s $RP CAP_EXP+0x10.w=$(printf '%04x' $(( 0x$cur | 0x20 ))) 2>/dev/null
    sleep 4
    case "$(link_now)" in *"$( [ "$LTGT" = 3 ] && echo 8.0 || echo 2.5) GT/s"*) break;; esac
  done
  log "link target=Gen$LTGT after ${try} retrain(s): $(gpu_state)"
fi

if [ "$(cat reboot-count)" -ge "$MAX_REBOOTS" ]; then
  log "HALT reboot budget ($MAX_REBOOTS) exhausted — inspect results.log"; exit 0
fi
[ "$DRY" = 1 ] && { log "DRY-RUN: step list from $STEPS"; awk -F'\t' '!/^#/&&NF{printf "  %-12s %4ss  %s\n",$1,$2,$4}' "$STEPS" | tee -a "$RESULTS"; exit 0; }

# A step may name the commands it needs in a 5th column; a missing tool is a
# SKIP-TOOL, never a result. (Steps 1-4 of the table are legacy and rely on the
# $STRESS/$HASHCAT checks above.)
missing_requires() { local r="" t
  for t in $1; do command -v "$t" >/dev/null 2>&1 || r="$r $t"; done
  echo "${r# }"; }

i=$(cat state); n=0
while IFS=$'\t' read -r name secs cmd hyp req; do
  case "$name" in ''|\#*) continue;; esac
  n=$((n+1)); [ "$n" -lt "$i" ] && continue
  break
done < "$STEPS"
log "LADDER-RESUME at step $i of $(awk -F'\t' '!/^#/&&NF' "$STEPS" | wc -l)"

n=0
while IFS=$'\t' read -r name secs cmd hyp req; do
  case "$name" in ''|\#*) continue;; esac
  n=$((n+1)); [ "$n" -lt "$i" ] && continue
  [ -e ABORT ] && { log "ABORT during ladder"; exit 0; }
  if [ -n "$ONLY" ] && ! echo ",$ONLY," | tr ',' '\n' | grep -qx "$name"; then
    log "SKIP-ONLY step=$n name=$name"; echo $((n+1)) > state; continue
  fi
  if [[ "$cmd" == *STRESS* && -z "$STRESS" ]] || [[ "$cmd" == *HASHCAT* && -z "$HASHCAT" ]]; then
    missing=$([ -z "$STRESS" ] && echo stress-ng; [ -z "$HASHCAT" ] && echo hashcat)
    log "SKIP-TOOL step=$n name=$name missing=\"$missing\" (install it or drop the step)"
    echo $((n + 1)) > state; continue
  fi
  if [ -n "$req" ]; then
    miss=$(missing_requires "$req")
    if [ -n "$miss" ]; then
      log "SKIP-TOOL step=$n name=$name missing=\"$miss\" (nix shell the bundle that provides it)"
      echo $((n + 1)) > state; continue
    fi
  fi
  sudo -n systemctl stop fah-client >/dev/null 2>&1 || true

  T0=$(date +%s); f=$(printf %02d $n)
  PLOG=runs/$f-$name.log; CSV=runs/$f-$name.csv
  log "STEP $n name=$name axis=\"$hyp\" seconds=$secs gpu=$(gpu_state)"
  sample "$CSV" & SPID=$!
  timeout $((secs + 90)) bash -c "$cmd $PROBE_ARGS" > "$PLOG" 2>&1
  RC=$?
  kill $SPID 2>/dev/null; wait $SPID 2>/dev/null
  LINK=$(gpu_state); TRANS=$(cat $CSV.transitions 2>/dev/null || echo 0)
  MARKER=$(grep -vE '^[[:space:]]*$' "$PLOG" 2>/dev/null | tail -1)
  JRN=$(die_marker "$T0"); DUR=$(( $(date +%s) - T0 ))
  ALIVE=yes; [ -n "$SMI" ] && { card_alive || ALIVE=no; }
  # rc=124 only means "the budget ran out". Evidence from 2026-11-20: the hashcat
  # step was called TIMEOUT-STALL and rebooted the box, but the card was alive, its
  # CSV held no bad samples, and the log was full of completed benchmark speeds - it
  # had simply not finished benchmarking. A real stall shows up as the card stopping
  # answering nvidia-smi inside the same window, so require that before calling one.
  UNRESP=0
  [ -n "$SMI" ] && UNRESP=$(awk -F, 'NR>1 && ($2 == "ERR" || $2 ~ /Nodevices/) {c++} END{print c+0}' "$CSV" 2>/dev/null)
  # A link that drops to Gen1 when the GPU goes idle and climbs back the moment load
  # arrives is behaving CORRECTLY (hardware autonomous speed setting). That is what
  # `link-transitions` was counting, and it made healthy steps look damning. The
  # signature that actually means something is a DOWNGRADE while the SMs are busy.
  LDROP=$(awk -F, 'NR>1 && $2 ~ /^[0-9.]+$/ {
      sp = ($10 ~ /^8\.0/ ? 8 : ($10 ~ /^5\.0/ ? 5 : 1))
      if (sp < prev && $8+0 > 80) c++
      prev = sp } END{print c+0}' "$CSV" 2>/dev/null)

  if   [ "$ALIVE" = no ];                          then VERDICT=DIED-CARD-GONE
  elif [ -n "$JRN" ];                              then VERDICT=DIED
  elif [ $RC -eq 124 ] && [ "${UNRESP:-0}" -gt 0 ]; then VERDICT=TIMEOUT-STALL
  elif [ $RC -eq 124 ];                            then VERDICT=TIMEOUT-SLOW
  elif [ $RC -eq 0 ];              then VERDICT=PASS
  elif [ $RC -eq 18 ];             then VERDICT=TOOLING-SKIP
  elif [ $RC -eq 17 ];             then VERDICT=DRIVER-ERR
  else VERDICT="RC-$RC"; fi

  log "RESULT step=$n name=$name verdict=$VERDICT rc=$RC dur=${DUR}s alive=$ALIVE link=$LINK link-transitions=$TRANS under-load-drops=${LDROP:-0} unresponsive-samples=$UNRESP last-marker=\"$MARKER\" journal=\"$JRN\""

  case "$VERDICT" in DIED|DIED-CARD-GONE|TIMEOUT-STALL)
    echo $((n + 1)) > state
    echo $(( $(cat reboot-count) + 1 )) > reboot-count
    if [ "$REBOOT" = 1 ]; then
      log "RECOVER rebooting to reclaim the bus (next step $((n + 1)), reboot #$(cat reboot-count))"
      sleep 10; sudo -n systemctl reboot; exit 0
    fi
    log "HALT --no-reboot: card is wedged; reboot by hand then re-run to continue at step $((n + 1))"
    exit 1;;
  esac
  echo $((n + 1)) > state
done < "$STEPS"

log "LADDER-COMPLETE steps=$n (see runs/*.csv for the telemetry; verdicts above)"
