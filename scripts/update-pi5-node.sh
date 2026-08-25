#!/usr/bin/env bash
# update-pi5-node.sh — end-to-end gc-node update for the Raspberry Pi 5:
#
#   1. pull the gc-rust-node source (tolerates a dirty tree / shallow clone)
#   2. re-lock the `path:` flake input (it is frozen at the locked narHash —
#      see pi5/ops-notes.md §4)
#   3. enroll a fresh single-use join code (the Pi is stateless: token lives
#      on tmpfs and every reboot needs a new code) and write it into
#      pi5/configuration.nix
#   4. rebuild the pi5-netboot artifact as root (store paths must be
#      root-owned, see pi5/ops-notes.md §2)
#   5. deploy the TFTP files and power-cycle the Pi via the HA relay
#   6. wait for ssh and verify gc-node / sshd / toplevel
#
# Usage: ./scripts/update-pi5-node.sh [options]
#   --join-code CODE   enrollment code for the new boot (default: auto-enroll
#                      from the demo gc-server on this host)
#   --no-update        skip the git pull in gc-rust-node
#   --no-reboot        deploy the TFTP files but do not power-cycle
#   --no-check         skip the post-boot service verification
#   --build-dir DIR    keep the netboot build in DIR (default: mktemp)
#   -h|--help          show this help
#
# Run WITHOUT sudo (sudo is used internally for the build + TFTP deploy).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PI5_DIR="$REPO_ROOT/pi5"
NODE_DIR="${GC_RUST_NODE_DIR:-$HOME/Projects/gc-business/gc-rust-node}"
GC_SERVER_DIR="${GC_SERVER_DIR:-$HOME/Projects/gc-business/gc-server}"
SERVER_CONFIG="${GC_SERVER_CONFIG:-$PI5_DIR/gc-server-demo.yaml}"
PI_HOST="pi5.grafton.lan"
PI_IP="192.168.49.92"
JOIN_TTL="${GC_JOIN_TTL:-24h}"
SSH_OPTS=(-o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR)

JOIN_CODE=""
DO_UPDATE=1
DO_REBOOT=1
DO_CHECK=1
BUILD_DIR=""

usage() {
  sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --join-code) JOIN_CODE="${2:-}"; shift 2 ;;
    --no-update) DO_UPDATE=0; shift ;;
    --no-reboot) DO_REBOOT=0; shift ;;
    --no-check) DO_CHECK=0; shift ;;
    --build-dir) BUILD_DIR="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown option: $1" >&2; usage 1 ;;
  esac
done

if [ "$(id -u)" = 0 ]; then
  echo "error: run without sudo (sudo is used internally where needed)" >&2
  exit 1
fi

# --- 1. update the node source ---------------------------------------------
if [ "$DO_UPDATE" = 1 ]; then
  if [ -d "$NODE_DIR/.git" ]; then
    echo "==> updating gc-rust-node ($NODE_DIR)"
    if ! git -C "$NODE_DIR" pull --ff-only --quiet; then
      echo "warning: git pull failed (dirty tree or shallow clone);" \
        "continuing with the local source" >&2
    fi
  else
    echo "warning: $NODE_DIR is not a git checkout; skipping source update" >&2
  fi
fi

# --- 2. re-lock the path input ----------------------------------------------
echo "==> re-locking the gc-rust-node flake input"
(cd "$PI5_DIR" && timeout 300 nix flake lock --update-input gc-rust-node)

# --- 3. enrollment code (single-use; needed for the new boot) ---------------
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
  echo "==> setting joinCode=$JOIN_CODE in pi5/configuration.nix"
  sed -i "s|joinCode = \"[^\"]*\"|joinCode = \"$JOIN_CODE\"|" "$PI5_DIR/configuration.nix"
fi

# --- 4. rebuild (as root so store paths are root-owned) ---------------------
if [ -z "$BUILD_DIR" ]; then
  BUILD_DIR="$(mktemp -d /tmp/pi5-out.XXXXXX)"
fi
# `nix build -o` creates a symlink and refuses an existing directory.
rm -rf "$BUILD_DIR"
echo "==> building pi5-netboot -> $BUILD_DIR"
sudo nix build --impure "path:$PI5_DIR#packages.aarch64-linux.pi5-netboot" -o "$BUILD_DIR"

EXPECTED_T="$(ls -d "$BUILD_DIR"/nixStore/nix-store/*nixos-system-pi5* 2>/dev/null | head -n1 || true)"
EXPECTED_T="$(basename "$EXPECTED_T")"
if [ -z "$EXPECTED_T" ]; then
  echo "error: no nixos-system-pi5 toplevel in the build output" >&2
  exit 1
fi
echo "    toplevel: $EXPECTED_T"

# --- 5. deploy + power-cycle -------------------------------------------------
echo "==> deploying TFTP files${DO_REBOOT:+ and power-cycling the Pi}"
if [ "$DO_REBOOT" = 1 ]; then
  sudo "$SCRIPT_DIR/deploy-pi5.sh" "$BUILD_DIR" --reboot
else
  sudo "$SCRIPT_DIR/deploy-pi5.sh" "$BUILD_DIR"
  echo "skipping reboot (--no-reboot)"
fi

if [ "$DO_CHECK" != 1 ] || [ "$DO_REBOOT" != 1 ]; then
  echo "done (verification skipped). build kept at: $BUILD_DIR"
  exit 0
fi

# --- 6. wait for boot + verify -------------------------------------------------
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

REMOTE_OUT="$(timeout 40 ssh "${SSH_OPTS[@]}" "root@$PI_HOST" bash -s <<'EOF'
echo "sys=$(readlink -f /run/current-system | sed 's|/nix/store/||')"
echo "gc-node=$(systemctl is-active gc-node)"
echo "sshd=$(systemctl is-active sshd)"
journalctl -u gc-node --no-pager | grep -E 'Subscribed|Running' | tail -n 1
EOF
)"
echo "$REMOTE_OUT"

CUR_SYS="$(printf '%s\n' "$REMOTE_OUT" | sed -n 's/^sys=//p')"
GC_ACTIVE="$(printf '%s\n' "$REMOTE_OUT" | sed -n 's/^gc-node=//p')"
SSHD_ACTIVE="$(printf '%s\n' "$REMOTE_OUT" | sed -n 's/^sshd=//p')"

FAIL=0
[ "$CUR_SYS" = "$EXPECTED_T" ] || { echo "FAIL: current-system is $CUR_SYS (expected $EXPECTED_T)"; FAIL=1; }
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
