#!/usr/bin/env bash
# update-pi5-node.sh — end-to-end gc-node update for the Raspberry Pi 5.
#
# The Pi's netboot files are now PART of the zen3-nixos system: the flake
# input gc-rust-node builds the pi5-netboot bundle (complete eeprom boot dir +
# store snapshot), and hosts/zen3-nixos/pi5-netboot.nix bind-mounts it at
# /etc/tftp/e9cf02dc (TFTP boot dir) and its nixStore/nix-store at
# /exports/nix-store (the Pi's NFS store — NOT this host's /nix/store).
# Deploying a Pi update therefore == a nixos-rebuild switch on zen3,
# followed by a power-cycle. This script drives the whole loop:
#
#   1. pull the gc-rust-node source (tolerates a dirty tree / shallow clone)
#      — the Pi's NixOS config lives in that repo (pi5/)
#   2. enroll a fresh single-use join code (the Pi is stateless: token lives
#      on tmpfs and every reboot needs a new code) and write it into
#      hosts/zen3-nixos/pi5-deploy.nix (the deployment values are passed to
#      gc-rust-node's lib.mkPi5Netboot — that repo contains no join codes)
#   3. re-lock the `gc-rust-node` path input in this repo's flake.lock
#      (path inputs freeze at the locked narHash — see pi5/ops-notes.md §4)
#   4. rebuild zen3 as root: sudo nixos-rebuild switch (builds the new
#      pi5-netboot on the MacBookAir, bind-mounts it into /etc/tftp)
#   5. sudo nixos-confirm (autoRollback is enabled on zen3!)
#   6. power-cycle the Pi via the HA relay
#   7. wait for ssh and verify gc-node / sshd / toplevel
#
# Usage: ./scripts/update-pi5-node.sh [options]
#   --join-code CODE   enrollment code for the new boot (default: auto-enroll
#                      from the demo gc-server on this host)
#   --no-update        skip the git pull in gc-rust-node
#   --no-rebuild       skip the nixos-rebuild (use the currently-deployed
#                      system; still power-cycles + verifies)
#   --no-reboot        skip the power-cycle
#   --no-check         skip the post-boot service verification
#   -h|--help          show this help
#
# Run WITHOUT sudo (sudo is used internally for the build + TFTP deploy).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
NODE_DIR="${GC_RUST_NODE_DIR:-$HOME/Projects/gc-business/gc-rust-node}"
GC_SERVER_DIR="${GC_SERVER_DIR:-$HOME/Projects/gc-business/gc-server}"
SERVER_CONFIG="${GC_SERVER_CONFIG:-$NODE_DIR/pi5/gc-server-demo.yaml}"
PI_HOST="pi5.grafton.lan"
PI_IP="192.168.49.92"
JOIN_TTL="${GC_JOIN_TTL:-24h}"
SSH_OPTS=(-o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR)

JOIN_CODE=""
DO_UPDATE=1
DO_REBUILD=1
DO_REBOOT=1
DO_CHECK=1

usage() {
  sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --join-code) JOIN_CODE="${2:-}"; shift 2 ;;
    --no-update) DO_UPDATE=0; shift ;;
    --no-rebuild) DO_REBUILD=0; shift ;;
    --no-reboot) DO_REBOOT=0; shift ;;
    --no-check) DO_CHECK=0; shift ;;
    -h|--help) usage ;;
    *) echo "unknown option: $1" >&2; usage 1 ;;
  esac
done

if [ "$(id -u)" = 0 ]; then
  echo "error: run without sudo (sudo is used internally where needed)" >&2
  exit 1
fi

# --- 1. update the node source -------------------------------------------------
if [ "$DO_UPDATE" = 1 ]; then
  if git -C "$NODE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "==> updating gc-rust-node ($NODE_DIR)"
    if ! git -C "$NODE_DIR" pull --ff-only --quiet; then
      echo "warning: git pull failed (dirty tree or shallow clone);" \
        "continuing with the local source" >&2
    fi
  else
    echo "warning: $NODE_DIR is not a git checkout; skipping source update" >&2
  fi
fi

# --- 2. enrollment code (single-use; needed for the new boot) ------------------
if [ -z "$JOIN_CODE" ]; then
  echo "==> enrolling a fresh join code from the demo gc-server"
  if [ -x "$GC_SERVER_DIR/.run/gc-server-demo" ] \
    && timeout 5 curl -fsS -o /dev/null http://127.0.0.1:8089/healthz 2>/dev/null; then
    ENROLL_OUT="$(cd "$GC_SERVER_DIR" \
      && timeout 60 ./.run/gc-server-demo enroll --ttl "$JOIN_TTL" -c "$SERVER_CONFIG" 2>&1)" \
      || ENROLL_OUT=""
    JOIN_CODE="$(printf '%s\n' "$ENROLL_OUT" | awk '/Enrollment code:/ {print $3; exit}')"
    if [ -z "$JOIN_CODE" ]; then
      echo "warning: could not obtain an enrollment code — the node will not" \
        "enroll after the reboot. Pass --join-code CODE to fix." >&2
      printf '%s\n' "$ENROLL_OUT" >&2
    else
      echo "    code: $JOIN_CODE (ttl $JOIN_TTL)"
    fi
  else
    echo "warning: demo gc-server not reachable on :8089; skipping auto-enroll" >&2
  fi
fi

if [ -n "$JOIN_CODE" ]; then
  echo "==> setting joinCode=$JOIN_CODE in hosts/zen3-nixos/pi5-deploy.nix"
  sed -i "s|joinCode = \"[^\"]*\"|joinCode = \"$JOIN_CODE\"|" "$REPO_ROOT/hosts/zen3-nixos/pi5-deploy.nix"
fi

# --- 3. re-lock the path input ---------------------------------------------------
echo "==> re-locking the gc-rust-node flake input"
(cd "$REPO_ROOT" && timeout 300 nix flake lock --update-input gc-rust-node)

# --- 4. rebuild zen3 (the Pi's boot files ARE this system now) -------------------
if [ "$DO_REBUILD" = 1 ]; then
  echo "==> nixos-rebuild switch on this host (--impure --flake .)"
  # The /exports root is exported with crossmnt (no /exports/nix-store
  # sub-export), so switch-to-configuration can replace the store bind mount
  # itself. Keep the tolerance as belt-and-braces (e.g. the old config is
  # still deployed, or the store is genuinely busy mid-boot).
  if ! sudo nixos-rebuild switch --impure --flake "$REPO_ROOT"; then
    echo "warning: nixos-rebuild exited non-zero (expected if only the" >&2
    echo "         store-export mount restart failed on a busy bind)" >&2
  fi

  # Safety net for when the switch above still couldn't replace the bind
  # (old config deployed, or a client holds the mount busy): drop any stale
  # sub-export, lazily detach the old bundle's layers, bind the NEW bundle's
  # snapshot, then re-export. (The running Pi keeps its NFS session; it is
  # power-cycled below anyway.)
  sudo exportfs -u /exports/nix-store 2>/dev/null || true
  for _ in 1 2 3 4; do sudo umount -l /exports/nix-store 2>/dev/null || break; done
  sudo systemctl restart 'exports-nix\x2dstore.mount' 2>/dev/null \
    || sudo mount /exports/nix-store
  sudo exportfs -ra 2>/dev/null || true

  # --- 5. confirm (autoRollback is enabled!) -------------------------------------
  echo "==> sudo nixos-confirm"
  sudo nixos-confirm
else
  echo "skipping nixos-rebuild (--no-rebuild)"
fi

# The pi5-netboot bundle the zen3 system serves (must exist: built by the
# rebuild above, or from a previous switch with --no-rebuild).
NETBOOT_DEV="$(nix eval --impure --raw \
  "$REPO_ROOT#nixosConfigurations.zen3-nixos.config.fileSystems.\"/etc/tftp/e9cf02dc\".device" 2>/dev/null)" \
  || NETBOOT_DEV=""
if [ -n "$NETBOOT_DEV" ]; then
  EXPECTED_T="$(ls -d "$NETBOOT_DEV"/nixStore/nix-store/*nixos-system-pi5* 2>/dev/null | head -n1 || true)"
  EXPECTED_T="$(basename "$EXPECTED_T")"
  [ -n "$EXPECTED_T" ] && echo "    toplevel: $EXPECTED_T" \
    || echo "warning: bundle not built yet ($NETBOOT_DEV)" >&2

  # The store export must now serve the NEW bundle (the switch couldn't
  # restart the mount on a busy bind; the fixup above did).
  MOUNT_SRC="$(findmnt -n -o SOURCE /exports/nix-store 2>/dev/null || true)"
  case "$MOUNT_SRC" in
    *"$NETBOOT_DEV"*) : ;;
    "") echo "FAIL: /exports/nix-store is not mounted" >&2; exit 1 ;;
    *) echo "FAIL: /exports/nix-store serves $MOUNT_SRC (expected the new bundle)" >&2; exit 1 ;;
  esac
else
  EXPECTED_T=""
  echo "warning: could not evaluate the pi5-netboot mount source" >&2
fi

# --- 6. power-cycle ---------------------------------------------------------------
echo "==> power-cycling the Pi${DO_REBOOT:+ via HA relay}"
if [ "$DO_REBOOT" = 1 ]; then
  "$SCRIPT_DIR/pi5-powercycle.sh"
else
  echo "skipping power-cycle (--no-reboot)"
fi

if [ "$DO_CHECK" != 1 ] || [ "$DO_REBOOT" != 1 ]; then
  echo "done (verification skipped)."
  exit 0
fi

# --- 7. wait for boot + verify ------------------------------------------------------
echo "==> waiting for $PI_HOST (ssh port) to come back up"
OK=0
for _ in $(seq 1 30); do
  sleep 10
  if timeout 3 bash -c "echo > /dev/tcp/$PI_IP/22" 2>/dev/null; then OK=1; break; fi
done
if [ "$OK" != 1 ]; then
  echo "FAIL: Pi did not answer on port 22 within 5 minutes" >&2
  exit 1
fi
echo "    ssh port open"

REMOTE_OUT="$(timeout 40 ssh "${SSH_OPTS[@]}" "root@$PI_HOST" bash -s <<EOF
echo "sys=\$(readlink -f /run/current-system | sed 's|/nix/store/||')"
echo "cmdline=\$(tr ' ' '\n' < /proc/cmdline | grep '^init=' | cut -d= -f2)"
echo "gc-node=\$(systemctl is-active gc-node)"
echo "sshd=\$(systemctl is-active sshd)"
journalctl -u gc-node --no-pager | grep -E 'Subscribed|Running' | tail -n 1
EOF
)"
echo "$REMOTE_OUT"

CUR_SYS="$(printf '%s\n' "$REMOTE_OUT" | sed -n 's/^sys=//p')"
CMDLINE_INIT="$(printf '%s\n' "$REMOTE_OUT" | sed -n 's/^cmdline=//p')"
GC_ACTIVE="$(printf '%s\n' "$REMOTE_OUT" | sed -n 's/^gc-node=//p')"
SSHD_ACTIVE="$(printf '%s\n' "$REMOTE_OUT" | sed -n 's/^sshd=//p')"

FAIL=0
if [ -n "$EXPECTED_T" ]; then
  [ "$CUR_SYS" = "$EXPECTED_T" ] || { echo "FAIL: current-system is $CUR_SYS (expected $EXPECTED_T)"; FAIL=1; }
  [ "$CMDLINE_INIT" = "/nix/store/$EXPECTED_T/init" ] \
    || { echo "FAIL: /proc/cmdline init is $CMDLINE_INIT (expected /nix/store/$EXPECTED_T/init)"; FAIL=1; }
else
  echo "note: no expected toplevel (eval failed earlier); skipping sys/cmdline checks"
fi
[ "$GC_ACTIVE" = "active" ] || { echo "FAIL: gc-node is $GC_ACTIVE"; FAIL=1; }
[ "$SSHD_ACTIVE" = "active" ] || { echo "FAIL: sshd is $SSHD_ACTIVE"; FAIL=1; }

# Server-side sanity check (informational; the demo server may not be running).
if timeout 5 curl -fsS http://127.0.0.1:8089/healthz >/dev/null 2>&1; then
  NODES="$(timeout 5 curl -s http://127.0.0.1:8089/healthz | grep -o '"nodes":[0-9]*' || true)"
  echo "demo server: $NODES"
fi

if [ "$FAIL" = 0 ]; then
  echo "ALL CHECKS PASSED"
else
  echo "SOME CHECKS FAILED" >&2
  exit 1
fi
