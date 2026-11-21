#!/bin/sh
# gpu-probe-fahcore-repro — re-run a saved Folding@home GPU work unit under the
# deployed service's OWN environment, with the client stopped and the original
# work directory left byte-for-byte untouched.
#
# Why this exists. On the Z240 heater the card has been cleared by every other
# test (12 traditional stress steps, 34 cold PCIe bring-ups, and the same CUDA
# workloads re-run inside the folding service's user/environment/sandbox) and the
# one thing never exercised is the core's actual compute path. The core's own log
# names it exactly:
#
#     GPU info: Compute: 6.1   GPU info: Driver: 13.0
#     Completed 0 out of 2500000 steps (0%)
#     Checkpoint completed at step 0
#     Watchdog triggered, requesting soft shutdown
#
# i.e. device enumeration succeeded, the first integration step never returned,
# and the watchdog killed the run ~12 min later. Two different GPUs in this box
# printed that same sentence and then diverged: the GTX 970 hung with no Xid at
# all (and its wedged NVML ioctl jammed nvidia-smi box-wide — the signature of a
# userspace path, not a bus), the GTX 1060 dropped off the bus with Xid 79 within
# seconds. Reproducing it here, with the client off and the WU copied, is what
# turns "the card is dead" into either a driver/userspace bug or a dead card.
#
#   gpu-probe-fahcore-repro                              # newest GPU WU, core 28
#   gpu-probe-fahcore-repro --work <uuid> --core 27      # a specific WU / older core
#   gpu-probe-fahcore-repro --setenv CUDA_MODULE_LOADING=EAGER
#   gpu-probe-fahcore-repro --cpu-load 8                 # heater condition: CPU slot too
#   gpu-probe-fahcore-repro --attempts 3 --seconds 600   # intermittency: same WU 3x
#   gpu-probe-fahcore-repro --work <uuid>                # a specific unit (see --help
#                                                        # of ls -t /var/lib/fah-client/work)
#   gpu-probe-fahcore-repro --dry-run
#
# It stops polling early — the fault, when it comes, comes in seconds, and a core
# wedged inside a driver ioctl is SIGKILL-proof, so on a card that has vanished the
# only honest answer is "reboot required", not a kill loop.
set -eu

WORK=/var/lib/fah-client/work
UNIT=fah-client
CORE=28
# NOT under /tmp or /var/tmp: the unit we launch inherits the real service's
# PrivateTmp=yes, so a scratch dir there does not exist inside its mount namespace
# and systemd dies with status=200/CHDIR before the core is ever executed — which
# looks exactly like "the core exited 200 in 7 seconds and wrote no log". /run is
# outside both PrivateTmp and ProtectHome (only /run/user is hidden), and tmpfs
# means the 28 MB WU copies disappear on their own at reboot.
SCRATCH=/run/fah-repro
SECS=900
CPULOAD=0
ATTEMPTS=1
SCRATCH_FRESH=0
PLATFORM=cuda
DRY=0
Wanted=
EXTRA_ENV=""

while [ $# -gt 0 ]; do
  case "$1" in
    --work) Wanted=$2; shift 2;;
    --core) CORE=$2; shift 2;;
    --unit) UNIT=$2; shift 2;;
    --scratch) SCRATCH=$2; shift 2;;
    --seconds) SECS=$2; shift 2;;
    --cpu-load) CPULOAD=$2; shift 2;;
    --attempts) ATTEMPTS=$2; shift 2;;
    --platform) PLATFORM=$2; shift 2;;
    --from-scratch) SCRATCH_FRESH=1; shift;;
    --setenv) EXTRA_ENV="$EXTRA_ENV --setenv=$2"; shift 2;;
    --dry-run) DRY=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

SMI=$(command -v nvidia-smi 2>/dev/null || ls /nix/store/*-nvidia-x11-*-bin/bin/nvidia-smi 2>/dev/null | head -1)
[ -n "$SMI" ] || { echo "no nvidia-smi: this repro is for the NVIDIA heaters" >&2; exit 3; }
[ -d "$WORK" ] || { echo "no folding work dir at $WORK" >&2; exit 3; }

# --- pick the work unit -------------------------------------------------------
# Which kind of WU a directory holds is written in its own core.xml: a GROMACS
# (CPU) unit carries `-core-args ... -s frame0.tpr`, an OpenMM (GPU) unit carries
# `<numSteps>`/`<energyTolerance>`. Guessing from the presence of a `01/` state dir
# is NOT enough — it matched a CPU unit and handed the GPU core a GROMACS WU.
kind_of() {
  xml=$(cat "$1/01/core.xml" 2>/dev/null || cat "$1/core.xml" 2>/dev/null)
  case "$xml" in *tpr*) echo cpu;; *numSteps*|*energyTolerance*) echo gpu;; *) echo other;; esac
}
if [ -z "$Wanted" ]; then
  for d in $(ls -1t "$WORK" 2>/dev/null); do
    [ "$(kind_of "$WORK/$d")" = gpu ] && { Wanted=$d; break; }
  done
fi
[ -n "$Wanted" ] || { echo "no GPU (OpenMM) work unit under $WORK — pass --work <uuid>" >&2; exit 2; }
[ "$(kind_of "$WORK/$Wanted")" = gpu ] || echo "NOTE: $Wanted looks like a $(kind_of "$WORK/$Wanted") unit, not OpenMM" >&2
[ -r "$WORK/$Wanted/wudata_01.dat" ] || { echo "$WORK/$Wanted has no wudata_01.dat" >&2; exit 2; }

# --- the core, and the GPU identity the client passes it ----------------------
COREDIR=$(ls -d /var/lib/fah-client/cores/openmm-core-$CORE/*/*/fahcore-$CORE-*-release-*/ 2>/dev/null | sort | tail -1)
COREDIR=${COREDIR%/}
[ -n "$COREDIR" ] && [ -x "$COREDIR/FahCore_$CORE" ] || { echo "openmm-core-$CORE is not installed" >&2; exit 3; }
GPU_UUID=$(timeout 25 $SMI --query-gpu=uuid --format=csv,noheader 2>/dev/null | head -1 | sed 's/^GPU-//')
GPU_NAME=$(timeout 25 $SMI --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
# Validate the shape, not just non-emptiness: with the card already dead, nvidia-smi
# prints "No devices were found" to STDOUT and exits 6, so the naive check handed the
# core a GPU uuid of "No devices were found" and dutifully ran the second arm against
# a bus that had nothing on it. A test like that does not merely fail, it lies.
case "$GPU_UUID" in
  [0-9a-f]*-[0-9a-f]*-[0-9a-f]*) ;;
  *) echo "REPRO-ERROR: no GPU on the bus (nvidia-smi said: '${GPU_UUID:-<empty>}')" \
       "— a reboot is the only thing that brings it back" >&2; exit 5;;
esac

# Exactly the argv the v8 client uses (read out of /var/lib/fah-client/logs/*.txt),
# minus -lifeline: the core polls that pid and hard-exits when it cannot signal it,
# and PID 1 is un-signalable by a service user (EPERM), so "-lifeline 1" makes the
# core quit immediately without writing a log. run-core.sh supplies a real one.
# (Note the core 8.3.1 reports "-gpu-uuid"/"-gpu-platform"/"-cuda-platform" as
# "Ignoring invalid or unsupported argument" — production prints the same warnings,
# so they are faithfully reproduced noise, not a bug here.)
ARGV="-dir $Wanted -suffix 01 -version 8.5.6 -gpu-uuid $GPU_UUID -gpu-platform $PLATFORM -gpu-vendor nvidia -opencl-platform 0 -opencl-device 0 -cuda-platform 0 -cuda-device 0 -gpu 0"
case "$PLATFORM" in
  # OpenMM has no "use this platform" env var, and the core ignores -gpu-platform on
  # 8.3.1, so the way to take CUDA away from it is to hide the device: with no CUDA
  # device visible, OpenMM's CUDA platform finds nothing and the core falls back to
  # the OpenCL ICD. If that arm survives, the fault is in the CUDA path specifically.
  opencl) EXTRA_ENV="$EXTRA_ENV --setenv=CUDA_VISIBLE_DEVICES=";;
esac

echo "repro: gpu=$GPU_NAME uuid=$GPU_UUID platform=$PLATFORM"
echo "repro: wu=$Wanted  core=$COREDIR"
echo "repro: argv=$ARGV"
[ "$DRY" = 1 ] && { echo "(dry run — nothing copied, nothing executed)"; exit 0; }

# --- keep the deployed client out of the way ---------------------------------
timeout 20 systemctl is-active --quiet "$UNIT" && {
  sudo -n systemctl stop "$UNIT"
  echo "repro: $UNIT stopped (runtime-masked; the flake re-enables it at the next boot)"
}
sudo -n systemctl mask --runtime "$UNIT" >/dev/null 2>&1 || true
sleep 3

# --- one attempt: fresh copy, run, watch the bus, read the instrument ----------
# The copy is re-made every attempt on purpose: the core rewrites its checkpoint and
# log in place, and a second attempt against the wreckage would be measuring the
# wreckage. The work dir under $WORK is never written.
attempt() {
  sudo -n rm -rf "$SCRATCH/work/$Wanted"
  sudo -n mkdir -p "$SCRATCH/work"
  sudo -n cp -a "$WORK/$Wanted" "$SCRATCH/work/"
  # the lock is a live-run artefact: a stale one makes the core refuse to start
  sudo -n rm -f "$SCRATCH/work/$Wanted/wudata_01.lock"
  # ALWAYS discard the copied log: the instrument must contain only this attempt.
  # Counting "Watchdog"/"Completed" lines from a copy of yesterday's failure is how
  # a clean 7-second run got read as REPRO-HUNG-AT-STEP-0.
  sudo -n rm -f "$SCRATCH"/work/$Wanted/logfile_01*.txt "$SCRATCH"/work/$Wanted/01/science.log
  if [ "$SCRATCH_FRESH" = 1 ]; then
    # Resume state is the whole difference between "continue a folded hour" and
    # "run the first integration step of the unit" — and the first step is the one
    # that has never been observed to survive here. Take it away and test that.
    # checkpt.crc is the checkpoint's OWN checksum and numRetries is how a core
    # decides it has already failed this WU too often: leave either behind with no
    # checkpoint and the core reports corrupt state instead of starting fresh.
    sudo -n rm -f "$SCRATCH/work/$Wanted/01/checkpoint" "$SCRATCH/work/$Wanted/01/stepsDone" \
                "$SCRATCH/work/$Wanted/01/state.cpt" "$SCRATCH/work/$Wanted/01/checkpt.crc" \
                "$SCRATCH/work/$Wanted/01/numRetries" "$SCRATCH/work/$Wanted/01/positions.xtc" \
                "$SCRATCH/work/$Wanted/01/"*.xtc "$SCRATCH/work/$Wanted/01/xtcAtoms.csv.bz2"
    sudo -n rm -f "$SCRATCH/work/$Wanted"/viewerFrame*.json "$SCRATCH/work/$Wanted/wuinfo_01.dat"
  fi
  sudo -n chown -R "$RUNUSER" "$SCRATCH"

  CARD_GONE=0; XID=""; RC=0; LOADPID=""; BUSY=0; UTILMAX=0; WPOLL=""
  if [ "$CPULOAD" -gt 0 ] && command -v stress-ng >/dev/null 2>&1; then
    stress-ng --cpu "$CPULOAD" --timeout $((SECS + 120)) --quiet & LOADPID=$!
  fi

  T0=$(date +%s)
  # The core wants a lifeline it can actually signal, so run it through a wrapper
  # that owns one: a sleep in the same namespace, left running for the whole budget.
  # Written through bash (the makeWrapper'd PATH guarantees it) rather than tee/stat,
  # which are not in the bundle's own binPath.
  # NOTE the `sh` placeholder: after `bash -c 'script' WORD`, WORD is $0, not $1 —
  # without it "$1" is empty, `cat > ""` fails, and the run reports a bogus verdict.
  printf '#!/bin/sh\nsleep %s &\nLL=$!\necho "run-core: lifeline=$LL user=$(id -un) cwd=$(pwd)"\nexec %s %s -lifeline "$LL"\n' \
    "$((SECS + 60))" "$COREDIR/FahCore_$CORE" "$ARGV" |
    sudo -n bash -c 'cat > "$1"; chmod 755 "$1"' sh "$SCRATCH/run-core.sh"
  # Prove the instrument exists before trusting its output — a placebo run is worse
  # than no run, and this script has produced two of them.
  sudo -n bash -c 'grep -q "FahCore" "$1"' sh "$SCRATCH/run-core.sh" || \
    { echo "REPRO-ERROR: $SCRATCH/run-core.sh was not written — refusing to run"; exit 4; }
  echo "repro: starting core (budget ${SECS}s; a fault usually lands in seconds)"
  # shellcheck disable=SC2086
  # --extra-ld is load-bearing, not a tweak: FahCore_28's own RPATH is the dead build
  # path /opt/conda/envs/build/lib, and it NEEDs libOpenMMCPU.so/libOpenMM.so by plain
  # soname. The client puts the core directory on the child's LD_LIBRARY_PATH (the
  # string is in the client binary); without that replication the core dies in the
  # loader with rc=127 and never reaches the GPU at all.
  gpu-probe-envtest --unit "$UNIT" --seconds "$SECS" --cwd "$SCRATCH/work" \
      --extra-ld "$COREDIR" --run "$SCRATCH/run-core.sh" $EXTRA_ENV -- &
  EPID=$!

  # Watch the bus AND the SMs, and log both, every 2 s. The core's own log is too
  # coarse to prove liveness — it prints "Completed N out of 2.5M steps" every 25 000
  # steps, ~6 minutes of folding — so GPU utilisation is what says "the first
  # integration step is running", and the power column is what says whether the death
  # was a load fault or a low-watts transition. Every command here must be `set -e`
  # safe: the first version assigned nvidia-smi's output in a bare VAR=$(...) line,
  # so the poll in which the card vanished killed the script (rc=6, nvidia-smi's own
  # "no devices" code) and the run that finally reproduced the fault reported nothing.
  CSV="$OUT/$(printf '%02d' "$i")-core$CORE-$(printf '%s' "$Wanted" | cut -c1-8).csv"
  echo "# epoch,util_pct,power_w,sm_mhz,mem_mib,temp_c  wu=$Wanted core=$CORE platform=$PLATFORM" > "$CSV"
  while kill -0 "$EPID" 2>/dev/null; do
    sleep 2
    if ! WPOLL=$(timeout 8 $SMI --query-gpu=utilization.gpu,power.draw,clocks.sm,memory.used,temperature.gpu \
                 --format=csv,noheader,nounits 2>/dev/null); then CARD_GONE=1; break; fi
    printf '%s,%s\n' "$(date +%s)" "$WPOLL" >> "$CSV"
    UTIL=$(printf '%s' "$WPOLL" | cut -d, -f1)
    if [ "${UTIL:-0}" -ge 50 ] 2>/dev/null; then BUSY=$((BUSY + 2)); fi
    if [ "${UTIL:-0}" -gt "${UTILMAX:-0}" ] 2>/dev/null; then UTILMAX=$UTIL; fi
    hit=$(timeout 25 journalctl -k --no-pager --since "@$T0" 2>/dev/null \
          | grep -m2 -oE 'Xid \(PCI:[0-9a-f:]+\): [0-9]+|fallen off the bus|AER: Uncorrectable' | tr '\n' ' ')
    if [ -n "$hit" ]; then XID="$hit"; break; fi
  done

  if [ "$CARD_GONE" = 1 ] || [ -n "$XID" ]; then
    echo "repro: fault after $(( $(date +%s) - T0 ))s — leaving the core alone (a wedged ioctl is SIGKILL-proof)"
  else
    wait "$EPID" || RC=$?
  fi
  [ -n "$LOADPID" ] && { kill "$LOADPID" 2>/dev/null || true; }
  sleep 2

  LOG=$(ls -t "$SCRATCH"/work/$Wanted/logfile_01*.txt 2>/dev/null | head -1)
  PROG=$(grep -hoE 'Completed [0-9]+ out of [0-9]+ steps' "$SCRATCH"/work/$Wanted/logfile_01*.txt 2>/dev/null | awk '{print $2}' | sort -n | tail -1)
  WD=$(grep -hc 'Watchdog triggered' "$SCRATCH"/work/$Wanted/logfile_01*.txt 2>/dev/null | awk '{s+=$1} END{print s+0}')
  if   [ "$CARD_GONE" = 1 ]; then VERDICT=REPRO-DIED-CARD-GONE
  elif [ -n "$XID" ];        then VERDICT=REPRO-DIED
  elif [ "$RC" = 200 ];      then VERDICT=CORE-EXIT-200   # results-ready — or CHDIR, see below
  elif [ "${WD:-0}" -gt 0 ]; then VERDICT=REPRO-HUNG-AT-STEP-0
  elif [ "${PROG:-0}" -gt 0 ]; then VERDICT=MAKING-PROGRESS
  elif [ "${BUSY:-0}" -ge 30 ]; then VERDICT=FOLDING-NO-LOG-LINE-YET
  elif [ "$RC" = 124 ];      then VERDICT=NO-GPU-WORK-TIMEOUT
  elif [ "$RC" = 0 ];        then VERDICT=CORE-EXIT-0
  else VERDICT="CORE-ERROR-$RC"; fi
  ALIVE=yes; timeout 8 $SMI --query-gpu=name --format=csv,noheader >/dev/null 2>&1 || ALIVE=no
  WMAX=$(awk -F, '!/^#/ && NF>3 {if ($3+0>w) w=$3+0} END{printf "%.1f", w+0}' "$CSV" 2>/dev/null)
  UMAX=$(awk -F, '!/^#/ && NF>3 {if ($2+0>u) u=$2+0} END{printf "%d", u+0}' "$CSV" 2>/dev/null)
  MARKER=$(tail -1 "$LOG" 2>/dev/null | tr -d '\r' | cut -c1-64)

  # Pull the core's own logs out of /run before the reboot this verdict forces: /run
  # is tmpfs, so the evidence of a kill is on the one filesystem a kill guarantees to
  # wipe. They are 0644, so no root needed to read them.
  for f in "$SCRATCH"/work/$Wanted/logfile_01*.txt "$SCRATCH"/work/$Wanted/01/science.log; do
    [ -f "$f" ] && cp -f "$f" "$OUT/$(printf '%02d' "$i")-$(basename "$f")" 2>/dev/null
  done

  echo "REPRO-VERDICT $VERDICT wu=$Wanted core=$CORE mode=$([ "$SCRATCH_FRESH" = 1 ] && echo from-scratch || echo resume) platform=$PLATFORM rc=$RC steps=${PROG:-0} watchdogs=${WD:-0} gpu-busy-secs=${BUSY:-0} util-max=${UTILMAX:-0}% peak-w=${WMAX:-?} telemetry=$CSV last-marker=\"$MARKER\" card-alive=$ALIVE dur=$(( $(date +%s) - T0 ))s kernel='${XID:-none}'"
  # Both ends of the log: the head proves it reached the CUDA platform, the tail is
  # where the fault writes itself. if/fi, not `[ -n ] && cmd` — under `set -e` that
  # returns 1 when the core wrote no log at all, which silently killed the script
  # right after the verdict and threw the run's output away.
  if [ -n "$LOG" ]; then
    echo "---- core log: head ----"; head -14 "$LOG" | sed 's/^/    > /'
    echo "---- core log: tail ----"; tail -5 "$LOG" | sed 's/^/    | /'
  else
    echo "    (no logfile_01.txt was written — the core did not get that far)"
    if [ "$RC" = 200 ]; then
      echo "    NOTE rc=200 with no log is systemd's CHDIR failure, not the core's exit code:"
      echo "    the unit could not enter WorkingDirectory=$SCRATCH/work. That happens when the"
      echo "    scratch dir sits under /tmp or /var/tmp while the unit inherits PrivateTmp=yes"
      echo "    (it did once — the whole repro silently 'passed' on a card that was never run)."
    fi
  fi
}

# The copy must be writable by the user the core will actually run as, which is the
# unit's User= — read from the unit rather than assumed, same principle as envtest.
RUNUSER=$(timeout 20 systemctl show "$UNIT" -p User --value 2>/dev/null)
[ -n "$RUNUSER" ] || RUNUSER=fah

# --- where the evidence goes --------------------------------------------------
# Deliberately NOT under $SCRATCH: /run is tmpfs and a reproduced kill is always
# followed by a reboot, so evidence written there is destroyed by the very event it
# documents. $XDG_STATE_HOME survives, and steps/corebisect.tsv relies on that.
OUT=${GPU_PROBE_REPRO_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/gpu-probe/repro}
mkdir -p "$OUT"
echo "repro: evidence dir=$OUT"

# --- pre-flight: refuse a scratch dir the launched unit cannot see ------------
# This is the difference between a test and a placebo: the first version of this
# script "ran" FahCore_28 on a card that was never executed, because systemd could
# not chdir into a /var/tmp path that PrivateTmp had replaced, and the resulting
# status=200 looked like a core exit code.
PTMP=$(timeout 20 systemctl show "$UNIT" -p PrivateTmp --value 2>/dev/null)
case "$SCRATCH" in
  /tmp|/tmp/*|/var/tmp|/var/tmp/*)
    if [ "$PTMP" = yes ]; then
      echo "REPRO-ERROR: --scratch $SCRATCH would not exist inside the unit ($UNIT has PrivateTmp=yes)." >&2
      echo "REPRO-ERROR: pick a path outside them, e.g. /run/fah-repro (the default)." >&2
      exit 4
    fi;;
esac
sudo -n mkdir -p "$SCRATCH/work"
sudo -n chown "$RUNUSER" "$SCRATCH"
echo "repro: scratch=$SCRATCH private-tmp-of-unit=$PTMP owner=$(sudo -n bash -c 'stat -c "%U:%a" "$1"' x "$SCRATCH")"

SUMMARY=""
i=0
while [ "$i" -lt "$ATTEMPTS" ]; do
  i=$((i + 1))
  echo "=== attempt $i of $ATTEMPTS ==="
  [ -e "$SCRATCH/ABORT" ] && { echo "ABORT marker present, stopping"; break; }
  attempt
  SUMMARY="$SUMMARY $VERDICT"
  case "$VERDICT" in
    REPRO-DIED*) echo "repro: the bus died — later attempts need a reboot first, stopping"; break;;
  esac
  [ "$i" -lt "$ATTEMPTS" ] && sleep 20
done
echo "REPRO-SUMMARY wu=$Wanted core=$CORE attempts=$i verdicts:$SUMMARY"
echo "repro: the copies are in $SCRATCH (the real work dir was never written)"
# Exit status is part of the instrument: steps/corebisect.tsv runs this inside the
# ladder, whose whole reboot-and-resume state machine keys off a step failing. A
# reproduced kill MUST therefore be non-zero, and a clean run zero — the first
# version exited 6 by accident (nvidia-smi's status code leaking through `set -e`),
# which happened to look like a kill but meant nothing.
case "$SUMMARY" in
  *REPRO-DIED*|*REPRO-HUNG*) echo "repro: EXIT 1 — fault reproduced"; exit 1;;
  *CORE-ERROR-*)             echo "repro: EXIT 2 — the core could not be run (not a verdict about the card)"; exit 2;;
esac
exit 0
