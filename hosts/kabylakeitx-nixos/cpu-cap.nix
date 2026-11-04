# kabylakeitx-nixos — CPU frequency cap: the only CPU fan control this box has.
#
# The ask was "slow the CPU fan down". There is no way to do that directly
# here. The ASRock B150N-GSM exposes no hardware monitor to Linux at all:
#
#   * every Super I/O driver fails to bind — `modprobe nct6775`, `it87`,
#     `f71882fg`, `w83627ehf` all die with "No such device" (the kernel ships
#     them as modules, the chip just is not answerable at the LPC addresses),
#   * the only hwmon devices are `coretemp` and `acpitz`, and there is not one
#     `fan*_input` or `pwm*` node anywhere under /sys,
#   * ACPI does enumerate five "Fan" cooling devices (PNP0C0B, cooling_device8
#     …12) but each has `max_state = 1` — on/off, not a speed — and they sit at
#     state 0 anyway.
#
# So the CPU fan is driven entirely by the BIOS Smart Fan logic, which reacts
# to temperature. The software lever is therefore indirect: stop the CPU making
# heat and the BIOS drops the fan by itself. Capping the ceiling is what does
# that, because the box has nothing to gain from boost clocks here — CPU
# folding is off (`<cpus>0</cpus>`), and the one CPU thread FAH uses is the
# CUDA core's busy-poll host thread, which does not care about its clock.
#
# Measured 2026-11-04 under the box's realistic worst case (FahCore_28 CUDA
# host thread + an eight-thread ffmpeg encode, load avg ~11):
#
#   scaling_max_freq 4200000  ->  package avg 92 °C (89-94), cur 4.00 GHz
#   scaling_max_freq 2400000  ->  package avg 64 °C (60-69), cur 2.40 GHz
#
# 28 °C for ~30 % of all-core encode throughput. FAH points are untouched —
# the work is on the RTX 2060, which is the real heater and the real noise
# source here (83 °C target, fan at 95 % while holding ~136 W; its power limit
# is the other lever, `nvidia-smi -pl 125`, min 125 W).
#
# Two things this deliberately does NOT do, both checked rather than assumed:
#
#   * It does not disable `power-profiles-daemon`. PPD holds the profile at
#     "performance" (EPP=performance, intel_pstate max_perf_pct=100), but on
#     intel_pstate it drives max_perf_pct/EPP, *not* scaling_max_freq —
#     verified by toggling profiles with a cap applied: all eight policies
#     stayed at 2400000 and cur_freq tracked it. So the cap survives PPD and
#     the Plasma profile menu keeps working. Do NOT move this to
#     `intel_pstate/max_perf_pct` instead: PPD does rewrite that one.
#   * It does not need a resume hook to fight the driver. With
#     `hardware.nvidia.powerManagement.enable = false` the TCC cooling driver
#     never loads, so no in-kernel cooling device clamps these policies. The
#     re-apply on suspend/resume below is only insurance (common/nosleep.nix
#     is currently commented out, so this desktop can suspend).
#
# Change the ceiling by editing capKHz, or at runtime with `cpu-cap 2600`
# (MHz or kHz, `cpu-cap off` removes it) — that is temporary until the next
# switch/boot, which re-applies capKHz.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  capKHz = 2400000;

  cpuCap = pkgs.writeShellScriptBin "cpu-cap" ''
    set -euo pipefail
    POL=/sys/devices/system/cpu/cpufreq

    SUDO=""
    [ "$(id -u)" -eq 0 ] || SUDO="sudo"

    policies() { ls -d "$POL"/policy* 2>/dev/null || true; }

    report() {
      local first; first="$(policies | head -1)"
      [ -n "$first" ] || { echo "no cpufreq policies under $POL" >&2; return 1; }
      echo "cap       : $(cat "$first/scaling_max_freq") kHz"
      echo "now       : $(cat "$POL"/policy*/scaling_cur_freq | tr '\n' ' ')"
      echo "epp       : $(cat "$first/energy_performance_preference" 2>/dev/null || echo n/a)"
      echo "pkg temp  : $(( $(cat /sys/class/thermal/thermal_zone2/temp) / 1000 )) C   load: $(cut -d' ' -f1-3 /proc/loadavg)"
    }

    apply() { # $1 = requested kHz
      local want="$1" got=0 p min
      local first; first="$(policies | head -1)"
      [ -n "$first" ] || { echo "no cpufreq policies under $POL" >&2; return 1; }
      local lo; lo="$(cat "$first/cpuinfo_min_freq")"
      local hi; hi="$(cat "$first/cpuinfo_max_freq")"
      # Clamp to what the driver will accept; an out-of-range write is EINVAL.
      [ "$want" -lt "$lo" ] && want="$lo"
      [ "$want" -gt "$hi" ] && want="$hi"
      for p in $(policies); do
        # A scaling_min_freq above the new ceiling makes the write fail.
        min="$(cat "$p/scaling_min_freq")"
        if [ "$min" -gt "$want" ]; then
          echo "$want" | $SUDO tee "$p/scaling_min_freq" >/dev/null
        fi
        echo "$want" | $SUDO tee "$p/scaling_max_freq" >/dev/null
        got=$((got + 1))
      done
      echo "capped $got policies at $want kHz"
      report
    }

    arg=''${1:-status}
    case "$arg" in
      status|""|show)
        report
        ;;
      off|max|none)
        apply "$(cat "$(policies | head -1)/cpuinfo_max_freq")"
        ;;
      *)
        case "$arg" in
          *[!0-9]*) echo "pass a frequency in MHz (2400) or kHz (2400000), or 'off'" >&2; exit 1 ;;
        esac
        # Accept MHz for readability: anything under 100000 cannot be kHz.
        [ "$arg" -lt 100000 ] && arg=$((arg * 1000))
        apply "$arg"
        ;;
    esac
  '';
in
{
  environment.systemPackages = [ cpuCap ];

  systemd.services.cpu-cap = {
    description = "Cap CPU frequency ceiling (fan noise on the B150N-GSM)";
    # Ordered after PPD so its boot-time profile application cannot race us,
    # and after the sleep targets so a resume re-applies the cap.
    after = [
      "power-profiles-daemon.service"
      "suspend.target"
      "hibernate.target"
      "hybrid-sleep.target"
    ];
    wantedBy = [
      "multi-user.target"
      "suspend.target"
      "hibernate.target"
      "hybrid-sleep.target"
    ];
    # Keys here are passed through to the unit file verbatim, so they are the
    # literal systemd names — camelCase (execStart) is silently "ignored" and
    # the unit lands as bad-setting with no ExecStart.
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # ${cpuCap} alone is the derivation's output *directory* — a writeShellScriptBin
      # package puts its script in bin/<name>, and systemd fails with
      # status=203/EXEC "Is a directory" if that suffix is left off.
      ExecStart = "${cpuCap}/bin/cpu-cap ${toString capKHz}";
    };
  };
}
