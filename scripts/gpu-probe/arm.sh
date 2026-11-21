#!/bin/sh
# arm/disarm the gpu-probe ladder so it survives the reboots it triggers itself.
#
# NixOS keeps /etc read-only (system units must come from the flake), so this
# installs a *user* unit with linger: it starts at boot as your user, which is
# enough for the probes (GPU devices are user-accessible) and uses `sudo -n` for
# the three privileged bits (power limit, PCIe retrain, reboot-on-kill).
#
#   gpu-probe-arm arm    [--steps xid79] [--link gen3] [--power-limit 120] [--no-reboot]
#   gpu-probe-arm status
#   gpu-probe-arm disarm
#   gpu-probe-arm reset            # clear step/reboot counters, keep the unit
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
while [ $# -gt 0 ]; do ARGS="$ARGS $1"; shift; done
case "$ARGS" in *"--state-dir $STATE_DIR --state-dir"*) echo "do not pass --state-dir; use GPU_PROBE_STATE_DIR" >&2; exit 2;; esac

case "$ACTION" in
  arm)
    mkdir -p "$HOME/.config/systemd/user" "$STATE_DIR"
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
