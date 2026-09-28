#!/usr/bin/env bash
# stress-monitor.sh — stress-ng soak with hardware telemetry and a verdict.
#
# WHY THIS EXISTS
#   zen3-nixos has a history of hard resets that leave no oops and no panic
#   (see docs/zen3-random-crashes.md). A bare `stress-ng ...` run tells you only
#   that stress-ng exited: it does not record die temperature, all-core clock,
#   package power or the GPU's state while the load was applied, and it cannot
#   attribute a kernel fault to the run. This wrapper does all of that.
#
# USAGE
#   scripts/stress-monitor.sh <TAG> <DURATION_SECONDS> <stress-ng args...>
#
# EXAMPLES
#   # 1. CPU compute + result verification. Passed cleanly on 2026-09-28 and
#   #    exonerated the CPU (16 workers, 12 min, 0 verify failures, 70 C peak).
#   scripts/stress-monitor.sh cpu 720 --cpu 16 --cpu-method all
#
#   # 2. Memory subsystem — the suspected fault. Soak it for an hour or more.
#   scripts/stress-monitor.sh mem 3600 \
#       --cpu 4 --cpu-method all \
#       --cache 4 --cache-enable-all --cache-permute \
#       --vm 4 --vm-bytes 2G --vm-method all \
#       --memthrash 2 --memthrash-method all
#
#   # 3. Run the network ones only if you WANT the GPU contested (it is on the
#   #    same PSU): --gpu measurement below is passive, it never loads the GPU.
#
# --verify is added automatically: for deterministic stressors (cpu, vm, ...)
# stress-ng recomputes its results and compares, so *silent* data corruption
# fails the run instead of passing it. A non-zero exit means "unstable".
#
# ENV OVERRIDES
#   INTERVAL=10        telemetry sample period, seconds
#   GPU_PCI=0000:03:00.0   which amdgpu to watch (default: the R9700)
#
# LOGS (in /tmp, ephemeral — paste the peaks into the doc if they matter)
#   /tmp/stress-<TAG>-<YYYYmmdd-HHMMSS>.{stress,monitor,summary}.log
#   monitor columns: tctl CPU die (k10temp), pkg RAPL package W, freq_avg
#   all-core MHz, gpu_junc GPU junction, gpu_ppt GPU board power, wmi_max
#   hottest board sensor (Gigabyte WMI), load.
#
# Requires stress-ng. sudo is used only for /sys/class/powercap/*/energy_uj and
# to write /dev/kmsg start/end markers (so new kernel faults are attributable to
# this window); the run still works without it, with pkg showing n/a.
set -uo pipefail

usage() { sed -n '5,44p' "$0"; }

TAG="${1:-}"
DUR="${2:-}"
if [ -z "$TAG" ] || [ -z "$DUR" ] || [ "$#" -lt 3 ]; then
  usage
  exit 2
fi
shift 2

INTERVAL="${INTERVAL:-10}"
GPU_PCI="${GPU_PCI:-0000:03:00.0}"

# ---- hardware discovery (nothing here is assumed to exist) ----------------
hwmon_by_name() {
  local h
  for h in /sys/class/hwmon/hwmon*; do
    [ "$(cat "$h/name" 2>/dev/null)" = "$1" ] && { printf '%s\n' "$h"; return 0; }
  done
  return 1
}
hwmon_by_dev() {
  local h
  for h in /sys/class/hwmon/hwmon*; do
    [ "$(cat "$h/name" 2>/dev/null)" = "$1" ] || continue
    [ "$(basename "$(readlink -f "$h/device" 2>/dev/null)")" = "$2" ] \
      && { printf '%s\n' "$h"; return 0; }
  done
  return 1
}

CPU_HW="$(hwmon_by_name k10temp || true)"
GPU_HW="$(hwmon_by_dev amdgpu "$GPU_PCI" || true)"
WMI_HW="$(hwmon_by_name gigabyte_wmi || true)"

RAPL=""
for d in /sys/class/powercap/*/; do
  if [ "$(cat "${d}name" 2>/dev/null)" = "package-0" ]; then RAPL="${d%/}"; break; fi
done

mtemp() { # millidegrees file -> integer C, or 0
  if [ -n "$1" ] && [ -r "$1" ]; then
    awk '{printf "%d", $1/1000}' "$1" 2>/dev/null || echo 0
  else
    echo 0
  fi
}
mwatt() { # microwatts file -> integer W, or 0
  if [ -n "$1" ] && [ -r "$1" ]; then
    awk '{printf "%d", $1/1000000}' "$1" 2>/dev/null || echo 0
  else
    echo 0
  fi
}
maxof() { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{print (a+0 > b+0) ? a : b}'; }
read_energy() {
  [ -n "$RAPL" ] && sudo -n cat "$RAPL/energy_uj" 2>/dev/null || echo 0
}

STAMP="$(date +%Y%m%d-%H%M%S)"
BASE="/tmp/stress-${TAG}-${STAMP}"
SLOG="${BASE}.stress.log"
MLOG="${BASE}.monitor.log"
SUMMARY="${BASE}.summary.log"
START_ISO="$(date -Is)"

printf 'tag=%s start_iso=%s dur=%ss interval=%ss gpu=%s args=%s\n' \
  "$TAG" "$START_ISO" "$DUR" "$INTERVAL" "${GPU_PCI:-none}" "$*" > "$MLOG"
printf 'stress_log=%s\nmonitor_log=%s\nsummary=%s\n' "$SLOG" "$MLOG" "$SUMMARY"

MAXUJ="$(cat "$RAPL/max_energy_range_uj" 2>/dev/null || echo 0)"
sudo -n sh -c "echo 'stress-monitor ${TAG} START ${START_ISO}' > /dev/kmsg" 2>/dev/null

# ---- run ------------------------------------------------------------------
stress-ng "$@" --timeout "${DUR}s" --verify --metrics-brief --times \
  --log-file "$SLOG" > "$SUMMARY" 2>&1 &
SPID=$!

prev_e="$(read_energy)"; prev_ns="$(date +%s%N)"
peak_tctl=0; peak_pkg=0; peak_gj=0; peak_wmi=0; samples=0; pkg_note=""

while :; do
  sleep "$INTERVAL"
  kill -0 "$SPID" 2>/dev/null || break

  now_ns="$(date +%s%N)"
  e="$(read_energy)"
  dt_ns=$(( now_ns - prev_ns ))
  de=$(( e - prev_e ))
  [ "$de" -lt 0 ] && de=$(( de + MAXUJ ))              # RAPL counter wraps
  pkg="$(awk -v de="$de" -v dt="$dt_ns" \
        'BEGIN{ if (dt > 0) printf "%.1f", de*1000/dt; else printf "0" }')"
  prev_e="$e"; prev_ns="$now_ns"

  tctl="$(mtemp "${CPU_HW:-}/temp1_input")"
  gj="$(mtemp "${GPU_HW:-}/temp2_input")"
  gppt="$(mwatt "${GPU_HW:-}/power1_average")"
  freq="$(awk '{s+=$1} END{ if (NR>0) printf "%d", s/NR/1000; else print 0 }' \
          /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null)"
  wmi="0"
  for i in 1 2 3 4 5 6; do
    wmi="$(maxof "$wmi" "$(mtemp "${WMI_HW:-}/temp${i}_input")")"
  done
  load="$(cut -d' ' -f1 /proc/loadavg)"

  printf '%s tctl=%s pkg=%sW freq_avg=%sMHz gpu_junc=%s gpu_ppt=%sW wmi_max=%s load=%s\n' \
    "$(date +%H:%M:%S)" "$tctl" "$pkg" "$freq" "$gj" "$gppt" "$wmi" "$load" >> "$MLOG"

  peak_tctl="$(maxof "$peak_tctl" "$tctl")"
  peak_pkg="$(maxof "$peak_pkg" "$pkg")"
  peak_gj="$(maxof "$peak_gj" "$gj")"
  peak_wmi="$(maxof "$peak_wmi" "$wmi")"
  samples=$(( samples + 1 ))
done

wait "$SPID"; rc=$?
END_ISO="$(date -Is)"
{
  printf 'end_iso=%s stress_exit=%s samples=%s\n' "$END_ISO" "$rc" "$samples"
  printf 'peak_tctl_c=%s peak_pkg_w=%s peak_gpu_junction_c=%s peak_wmi_max_c=%s\n' \
    "$peak_tctl" "$peak_pkg" "$peak_gj" "$peak_wmi"
  [ -n "$RAPL" ] || printf 'note=no RAPL package-0 counter found; pkg is n/a\n'
} >> "$MLOG"
sudo -n sh -c "echo 'stress-monitor ${TAG} END rc=${rc}' > /dev/kmsg" 2>/dev/null

cat "$SUMMARY"
printf '\n--- peaks ---\n'
tail -3 "$MLOG"
if [ "$rc" -eq 0 ]; then
  printf '\nVERDICT: PASS (exit 0, %d samples)\n' "$samples"
else
  printf '\nVERDICT: FAIL (exit %d) — inspect %s and journalctl -k\n' "$rc" "$SLOG"
fi
exit "$rc"
