#!/usr/bin/env bash
#
# Convenience wrapper for the `win7` guest used by the PCTV 320cx capture work
# (see docs/pctv-320cx.md §5.4).
#
# Resolves the guest's IP from the libvirt DHCP leases, makes sure the libvirt
# `default` network (and optionally the VM) is running, and connects with the
# right key/options. Avoids having to remember the ssh flags every time.
#
# Usage:
#   ./scripts/pctv-win7-ssh.sh                          # interactive cmd
#   ./scripts/pctv-win7-ssh.sh 'dir C:\Users\Chris'     # run a command
#   ./scripts/pctv-win7-ssh.sh --get 'C:/Users/Chris/frame.raw' /tmp/frame.raw
#   ./scripts/pctv-win7-ssh.sh --put /tmp/tool.cs 'C:/Users/Chris/tool.cs'
#
# Options:
#   --password     use password auth (default PCTV_WIN7_PASSWORD, else "password")
#   --start        start the win7 domain if it is not running
#   --ip ADDR      skip lease lookup and use ADDR
#   -h|--help      this text
#
# Env: PCTV_WIN7_KEY (default ~/.ssh/pctv_win7_ed25519)
#      PCTV_WIN7_USER (default Chris)
#      PCTV_WIN7_DOMAIN (default win7)
#      PCTV_WIN7_PASSWORD (default "password")

set -euo pipefail

DOMAIN="${PCTV_WIN7_DOMAIN:-win7}"
USER_NAME="${PCTV_WIN7_USER:-Chris}"
KEY="${PCTV_WIN7_KEY:-$HOME/.ssh/pctv_win7_ed25519}"
PASSWORD="${PCTV_WIN7_PASSWORD:-password}"
FALLBACK_IP="192.168.122.59"

USE_PASSWORD=0
DO_START=0
FORCE_IP=""
MODE=ssh
SRC=""
DST=""

die() { echo "pctv-win7-ssh: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --password) USE_PASSWORD=1; shift ;;
    --start)    DO_START=1; shift ;;
    --ip)       FORCE_IP="${2:-}"; shift 2 ;;
    --get)      MODE=get; SRC="${2:-}"; DST="${3:-}"; shift 3 ;;
    --put)      MODE=put; SRC="${2:-}"; DST="${3:-}"; shift 3 ;;
    -h|--help)  awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; exit 0 ;;
    *) break ;;
  esac
done

virsh_c() { virsh --connect qemu:///system "$@"; }

# --- make sure the libvirt default network is up (it has been left down by reboots)
# NB: capture the output rather than piping into `grep -q` — grep exits early, virsh
# takes SIGPIPE, and `set -o pipefail` would then make a *successful* check look failed.
net_info="$(virsh_c net-info default 2>/dev/null || true)"
case "$net_info" in
  *Active:*yes*) : ;;
  *) echo "pctv-win7-ssh: starting libvirt network 'default'" >&2
     virsh_c net-start default >/dev/null 2>&1 || true ;;
esac

# --- optionally boot the guest
if [ "$DO_START" = 1 ]; then
  state="$(virsh_c domstate "$DOMAIN" 2>/dev/null || echo unknown)"
  if [ "$state" != "running" ]; then
    echo "pctv-win7-ssh: starting domain '$DOMAIN'" >&2
    virsh_c start "$DOMAIN" >/dev/null 2>&1 || true
  fi
fi

# --- resolve the IP (awk `exit` avoids SIGPIPE / pipefail surprises)
IP="$FORCE_IP"
leases="$(virsh_c net-dhcp-leases default 2>/dev/null || true)"
if [ -z "$IP" ]; then
  IP="$(printf '%s\n' "$leases" \
        | awk -v h="$USER_NAME" '$0 ~ /ipv4/ && $0 ~ h {print $5; exit}' \
        | cut -d/ -f1)"
fi
# fall back to the most recent lease, then to the known address
if [ -z "$IP" ]; then
  IP="$(printf '%s\n' "$leases" \
        | awk '/ipv4/ {last=$5} END {print last}' | cut -d/ -f1)"
fi
[ -n "$IP" ] || IP="$FALLBACK_IP"

COMMON_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=8
)

TMPASK=""
cleanup() { [ -n "$TMPASK" ] && rm -f "$TMPASK"; }
trap cleanup EXIT

if [ "$USE_PASSWORD" = 1 ]; then
  TMPASK="$(mktemp /tmp/pctv-askpass-XXXXXX.sh)"
  printf '#!/bin/sh\nprintf "%%s\\n" %q\n' "$PASSWORD" > "$TMPASK"
  chmod +x "$TMPASK"
  AUTH_OPTS=(
    -o PreferredAuthentications=password
    -o PubkeyAuthentication=no
    -o NumberOfPasswordPrompts=1
  )
  run_ssh() {
    SSH_ASKPASS="$TMPASK" SSH_ASKPASS_REQUIRE=force \
      ssh "${COMMON_OPTS[@]}" "${AUTH_OPTS[@]}" "$USER_NAME@$IP" "$@"
  }
else
  [ -f "$KEY" ] || die "key not found: $KEY (use --password, or see docs/pctv-320cx.md §5.4.1)"
  AUTH_OPTS=( -o IdentitiesOnly=yes -o BatchMode=yes )
  run_ssh() {
    ssh -i "$KEY" "${COMMON_OPTS[@]}" "${AUTH_OPTS[@]}" "$USER_NAME@$IP" "$@"
  }
fi

scp_common() { :; }

case "$MODE" in
  ssh)
    if [ $# -eq 0 ]; then
      exec ssh -i "$KEY" "${COMMON_OPTS[@]}" "${AUTH_OPTS[@]}" "$USER_NAME@$IP"
    fi
    run_ssh "$@"
    ;;
  get)
    [ -n "$SRC" ] && [ -n "$DST" ] || die "--get needs <guest-path> <local-path>"
    if [ "$USE_PASSWORD" = 1 ]; then
      # scp honours $SSH_ASKPASS only via -o; simplest is to reuse ssh's askpass
      SSH_ASKPASS="$TMPASK" SSH_ASKPASS_REQUIRE=force \
        scp "${COMMON_OPTS[@]}" "${AUTH_OPTS[@]}" "$USER_NAME@$IP:$SRC" "$DST"
    else
      scp -i "$KEY" "${COMMON_OPTS[@]}" "${AUTH_OPTS[@]}" "$USER_NAME@$IP:$SRC" "$DST"
    fi
    ;;
  put)
    [ -n "$SRC" ] && [ -n "$DST" ] || die "--put needs <local-path> <guest-path>"
    if [ "$USE_PASSWORD" = 1 ]; then
      SSH_ASKPASS="$TMPASK" SSH_ASKPASS_REQUIRE=force \
        scp "${COMMON_OPTS[@]}" "${AUTH_OPTS[@]}" "$SRC" "$USER_NAME@$IP:$DST"
    else
      scp -i "$KEY" "${COMMON_OPTS[@]}" "${AUTH_OPTS[@]}" "$SRC" "$USER_NAME@$IP:$DST"
    fi
    ;;
esac
