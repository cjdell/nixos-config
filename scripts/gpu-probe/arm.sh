#!/bin/sh
# arm/disarm the gpu-probe ladder so it survives the reboots it triggers itself.
#
# NixOS keeps /etc read-only (system units must come from the flake), so this
# installs a *user* unit with linger: it starts at boot as your user, which is
# enough for the probes (GPU devices are user-accessible) and uses `sudo -n` for
# the three privileged bits (power limit, PCIe retrain, reboot-on-kill).
#
#   gpu-probe-arm arm    [--steps xid79] [--link gen3] [--power-limit 120]
#
# Reboots are MANUAL by default: on a kill the ladder records the verdict and HALTS,
# you reboot, and `arm` again (or re-run gpu-probe-ladder) resumes at the next step.
# Only add --reboot-on-kill on a headless box you can afford to cycle — see ladder.sh.
#   gpu-probe-arm status
#   gpu-probe-arm disarm
#   gpu-probe-arm reset            # clear step/reboot counters, keep the unit
#   gpu-probe-arm hold    fah-client   # stop a deployed service from starting at boot
#   gpu-probe-arm release fah-client   #   (survives reboots; see the hold block)
#
# GPU_PROBE_HOLD_FOLDING=<unit> in the environment makes `hold` part of `arm`.
#
# Any option after `arm` is passed straight to gpu-probe-ladder.
set -eu

ACTION=${1:-arm}
shift || true
UNIT=${GPU_PROBE_UNIT:-gpu-probe}
# One state dir per campaign: results.log, the step counter and the ABORT/mask-fah
# markers all live there, so a second ladder run cannot clobber the first one's
# evidence.  GPU_PROBE_STATE_DIR overrides it and is passed to the ladder as well,
# so arm and run always agree on where the evidence goes.
STATE_DIR=${GPU_PROBE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/gpu-probe}
LADDER=${GPU_PROBE_LADDER:-$(command -v gpu-probe-ladder || echo /run/current-system/sw/bin/gpu-probe-ladder)}
SLEEP=$(command -v sleep || echo /run/current-system/sw/bin/sleep)

ARGS="--state-dir $STATE_DIR"
EXTRA_ARGS="$*"
while [ $# -gt 0 ]; do ARGS="$ARGS $1"; shift; done
case "$ARGS" in *"--state-dir $STATE_DIR --state-dir"*) echo "do not pass --state-dir; use GPU_PROBE_STATE_DIR" >&2; exit 2;; esac

# --- the boot-time hold ---------------------------------------------------------
# A runtime mask dies with the boot, so every boot gives the deployed folding client
# a ~90 s head start (the ladder sleeps 60 s first, to let the compositor come up, and
# the client's own startDelay is ~90 s). On a card that goes off the bus within seconds
# of FahCore_28 reaching step 0, that head start IS the experiment: observed
# 2026-11-21, boot 01:30:05, client up, ladder masked it at 01:31:03, the restart race
# brought it back anyway and the card was dead at 01:32:40.
#
# So install the hold EARLIER instead: the user unit masks+stops the client in its own
# ExecStartPre, BEFORE the 60 s compositor sleep, which lands at ~+13 s of boot rather
# than +60 s — ~90 s of margin before the client's core could spawn. Manual drop-ins
# are not available to do this with: /etc/systemd/system is a read-only bind on NixOS
# (mkdir fails EROFS) and a persistent `systemctl mask` is refused because NixOS owns
# /etc/systemd/system/<unit>.service. A runtime mask is therefore the only lever, and
# the answer to it dying at every boot is to re-apply it from the unit, early.
#
# The safety net that makes this honest either way: gpu-probe-fahcore-repro ASSERTS the
# client is inactive before running and refuses otherwise, and the ladder treats that as
# a HALT that does not advance the step counter. Lose the race and the campaign stops
# instead of filling itself with false PASSes.
FOLD_UNIT=${GPU_PROBE_HOLD_FOLDING:-}
SUDO=$(command -v sudo || echo /run/wrappers/bin/sudo)

gate_install() {
  gate_u=$1
  # MASK BEFORE STOP: a stop on a Restart= unit queues a restart, and masking after it
  # (same second) does not catch it — the exact sequence that killed the card at
  # 01:32:40 on 2026-11-21.
  sudo -n systemctl mask --runtime "$gate_u" >/dev/null 2>&1 || true
  sudo -n systemctl stop "$gate_u" >/dev/null 2>&1 || true
  sudo -n systemctl reset-failed "$gate_u" >/dev/null 2>&1 || true
  gate_st=unknown
  for gate_i in 1 2 3 4 5 6 7 8; do
    gate_st=$(timeout 15 systemctl is-active "$gate_u" 2>/dev/null || true)
    [ "$gate_st" = inactive ] && break
    sudo -n systemctl stop "$gate_u" >/dev/null 2>&1 || true
    sleep 2
  done
  if [ "$gate_st" = inactive ]; then
    echo "hold:    $gate_u runtime-masked + verified inactive"
    if [ -z "$FOLD_UNIT" ]; then
      echo "hold:    NOTE a runtime mask dies at boot. To re-apply it automatically, arm with"
      echo "hold:      GPU_PROBE_HOLD_FOLDING=$gate_u gpu-probe-arm arm ..."
    else
      echo "hold:    re-applied at every boot from the ladder unit's ExecStartPre (before its sleep)"
    fi
  else
    echo "hold:    FAILED — $gate_u is still $gate_st. Do not trust any result from here." >&2
    return 1
  fi
}

gate_remove() {
  rel_u=$1
  sudo -n systemctl unmask --runtime "$rel_u" >/dev/null 2>&1 || true
  sudo -n systemctl unmask "$rel_u" >/dev/null 2>&1 || true
  echo "release: $rel_u unmasked — folding can start again"
  echo "         (an armed ladder still masks it at boot; 'gpu-probe-arm disarm' stops that)"
}

case "$ACTION" in
  hold)
    gate_u=${EXTRA_ARGS:-$FOLD_UNIT}
    [ -n "$gate_u" ] || { echo "hold needs a unit: gpu-probe-arm hold fah-client" >&2; exit 2; }
    gate_install "$gate_u"
    ;;
  release)
    rel_u=${EXTRA_ARGS:-$FOLD_UNIT}
    [ -n "$rel_u" ] || { echo "release needs a unit: gpu-probe-arm release fah-client" >&2; exit 2; }
    gate_remove "$rel_u"
    ;;
  arm)
    mkdir -p "$HOME/.config/systemd/user" "$STATE_DIR"
    # GPU_PROBE_HOLD_FOLDING=<unit> makes the hold part of arming, so the campaign
    # cannot be raced by the deployed client across the reboots it triggers itself.
    if [ -n "$FOLD_UNIT" ]; then gate_install "$FOLD_UNIT"; fi
    # Same hold, re-applied at the very start of every boot — before the compositor
    # sleep below, and so ~90 s before the client's core could spawn. `-` prefixes so a
    # unit that is already inactive cannot fail the ladder's own startup.
    HOLD_LINES=""
    if [ -n "$FOLD_UNIT" ]; then
      # The pkill is not decoration: a FahCore orphaned by a PREVIOUS boot's kill (its
      # client died with the bus, the core stays in a driver ioctl at 99 % CPU) survives
      # into the new boot holding a dead context. It then either trips the repro's
      # "client must be inactive" assert or sits on the GPU so the step is not measuring
      # what the table says it measures. `-` because "no orphans" (exit 1) is success.
      HOLD_LINES="ExecStartPre=-$SUDO -n systemctl mask --runtime $FOLD_UNIT
ExecStartPre=-$SUDO -n systemctl stop $FOLD_UNIT
ExecStartPre=-$SUDO -n systemctl reset-failed $FOLD_UNIT
ExecStartPre=-$SUDO -n /run/current-system/sw/bin/pkill -9 -f [F]ahCore_"
    fi
    # A heater's folding client must not compete with the probes (delete this
    # marker file if you want the ladder to leave it alone).
    touch "$STATE_DIR/mask-fah"
    cat > "$HOME/.config/systemd/user/$UNIT.service" <<EOF
[Unit]
Description=GPU fault repro ladder (gpu-probe)
Documentation=file://$STATE_DIR/results.log

[Service]
Type=oneshot
RemainAfterExit=yes
# The ladder must find the same tools after the reboot it triggered itself, and a
# GL step must find the compositor: a heater folds with the console on the same
# card, so the desktop path is part of the test condition, not something to
# exclude from it. Both are inherited from the shell that armed the ladder
# (gpu-probe's own wrapper prepends its PATH, so PATH here is belt-and-braces).
Environment=PATH="$PATH"
Environment=DISPLAY="${DISPLAY:-}"
Environment=WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}"
Environment=XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
Environment=DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-}"
# Hold the deployed folding client off first (these lines are empty unless
# GPU_PROBE_HOLD_FOLDING was set) — the runtime mask has to be re-created every boot,
# and it has to beat the client's ~90 s startDelay, not the ladder's own preamble.
$HOLD_LINES
# Let the desktop/compositor come up first: a real heater folds with the console
# on the same card, so that is part of the test condition.
ExecStartPre=$SLEEP 60
ExecStart=$LADDER $ARGS
StandardOutput=append:$STATE_DIR/harness.log
StandardError=inherit
TimeoutStartSec=infinity

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable "$UNIT.service"
    loginctl enable-linger "$(id -un)" 2>/dev/null \
      || echo "WARN: enable-linger failed — the ladder will NOT resume after a reboot" >&2
    # `restart`, never `start`: the unit is Type=oneshot + RemainAfterExit, so a
    # finished campaign stays active(exited) — and `start` on an already-active unit
    # is a SILENT no-op, which looks like "armed" and then produces no results.log.
    systemctl --user reset-failed "$UNIT.service" 2>/dev/null || true
    systemctl --user restart "$UNIT.service"
    echo "armed.   results: $STATE_DIR/results.log"
    # Say the reboot policy out loud, at the moment it matters. A campaign that reboots
    # an unattended box whose console is on the dying card is an operator lockout, and
    # "armed" without that line is how it happened on hp-z240 on 2026-11-21.
    case " $ARGS " in
      *"--reboot-on-kill"*)
        echo "reboots: ARMED but gated — it still needs GPU_PROBE_I_CONSENT_TO_REBOOT=1 in the"
        echo "             environment at the moment of the kill. Cancel in the grace window:"
        echo "             touch $STATE_DIR/ABORT" ;;
      *)  echo "reboots: OFF (default) — on a kill the ladder HALTS. Reboot by hand, then"
          echo "             re-run the same command to resume at the next step." ;;
    esac
    # Print what the unit will actually exec: this line has caught quoting and
    # concatenation bugs in the ExecStart template more than once, and after a
    # reboot-triggering campaign a silent typo here costs the whole run.
    echo "exec:    $(grep '^ExecStart=' "$HOME/.config/systemd/user/$UNIT.service" | cut -d= -f2-)"
    echo "watch:     gpu-probe-arm status"
    echo "stop now:  gpu-probe-arm disarm   (or: touch $STATE_DIR/ABORT)"
    ;;
  status)
    [ -r "$STATE_DIR/results.log" ] || { echo "no results yet ($STATE_DIR/results.log)"; exit 0; }
    grep -E 'BOOT|link|RESULT|RECOVER|HALT|LADDER' "$STATE_DIR/results.log" | tail -25
    echo "-- state: step=$(cat "$STATE_DIR/state" 2>/dev/null) reboots=$(cat "$STATE_DIR/reboot-count" 2>/dev/null)"
    ;;
  reset)
    rm -f "$STATE_DIR/state" "$STATE_DIR/reboot-count"
    echo "counters cleared; re-run 'gpu-probe-arm disarm && gpu-probe-arm arm ...' to restart the ladder"
    ;;
  disarm)
    systemctl --user stop "$UNIT.service" 2>/dev/null || true
    systemctl --user disable "$UNIT.service" 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/$UNIT.service"
    systemctl --user daemon-reload
    echo "disarmed (linger left as-is; pkill the ladder if it is mid-step)"
    ;;
  *)
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
