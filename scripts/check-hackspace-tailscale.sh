#!/usr/bin/env bash
# check-hackspace-tailscale.sh — why can't I reach the leighhack tailnet?
#
# There are TWO tailscale connections on grafton-router and they are unrelated:
#
#   * the grafton tailnet  — tailscaled on the host, coordination server
#     https://tailscale.home.chrisdell.info (our own headscale). `tailscale status`.
#   * the leighhack tailnet — coordination server https://tailscale.leighhack.org
#     (the hackspace's headscale). Reached ONLY through the
#     grafton-hackspace-client microVM, which advertises 192.168.49.0/24 there
#     and accepts its routes; the host reaches it via a hand-written
#     `ip route 10.3.0.0/16 via 192.168.49.15` (grafton-hackspace-client-routes).
#
# So "tailscale is fine" (`tailscale status` looks healthy!) says nothing about
# leighhack, which is why this outage was invisible for days. `*.int.leighhack.org`
# resolves through adguard.nix forwarding that zone to 10.3.1.1:53, so the first
# visible symptom is usually DNS failing, not a VPN looking down.
#
# Run this FIRST, from grafton-router, when leighhack is unreachable. It walks
# the path from the host inward and names the layer that broke.
#
#   sudo ~/nixos-config/scripts/check-hackspace-tailscale.sh
#   sudo ~/nixos-config/scripts/check-hackspace-tailscale.sh --console
#
# --console attaches to the microVM's serial console over the QEMU QMP socket.
# That VM has no disk, no VSOCK (`microvm -s` refuses) and its serial is qemu's
# stdio, so before root's authorizedKeys were added the QMP chardev swap below
# was the only way in. It is read-only in effect: it moves the console, it does
# not touch the guest.
#
# Background and the fix: docs/leighhack-tailscale.md
#
# Layers, outermost first:
#   1 route    ip route 10.3.0.0/16 via 192.168.49.15 installed?
#   2 vm       microvm@grafton-hackspace-client running, and answering ping?
#   3 session  is the VM's tailscaled logged in to leighhack?  <- usual culprit
#   4 tunnel   does 10.3.1.1 (services1) actually answer?
#   5 dns      does *.int.leighhack.org resolve (the downstream consumer)?

set -uo pipefail

VM=grafton-hackspace-client
VM_IP=192.168.49.15
HACKSPACE_IP=10.3.1.1
COORD=https://tailscale.leighhack.org
QMP=/var/lib/microvms/$VM/$VM.sock
CONSOLE=/run/microvm-console/$VM.sock

# One command inside the bridge VM. From an interactive shell this uses the
# agent keys; as root (no agent) it uses the deployed sops key if present.
vmrun() {
  local keyopt=()
  [ -r /run/secrets/grafton_hackspace_client_ssh_key ] \
    && keyopt=(-i /run/secrets/grafton_hackspace_client_ssh_key)
  ssh -o BatchMode=yes -o LogLevel=ERROR -o StrictHostKeyChecking=no \
      "${keyopt[@]}" -o UserKnownHostsFile=/dev/null -o ConnectTimeout=6 \
      "root@$VM_IP" "$1" 2>/dev/null
}

pass=0; fail=0; skip=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
skip() { printf '  \033[33mSKIP\033[0m %s\n' "$1"; skip=$((skip+1)); }
note() { printf '       %s\n' "$1"; }
hdr() { printf '\n\033[1m%s\033[0m\n' "$1"; }

SUDO=""; amroot=0
if [ "$(id -u)" = 0 ]; then
  amroot=1
elif sudo -n true 2>/dev/null; then
  SUDO="sudo -n"; amroot=1
else
  note "not root: the VM console and qemu checks will be skipped"
fi

if [ "$(hostname)" != "grafton-router" ]; then
  echo "This host is $(hostname); the leighhack bridge only exists on grafton-router."
  echo "Run it there:  ssh grafton-router.grafton.lan 'sudo ~/nixos-config/scripts/check-hackspace-tailscale.sh'"
  exit 2
fi

if [ "${1:-}" = "--console" ]; then
  command -v nix >/dev/null || { echo "nix not on PATH"; exit 1; }
  $SUDO mkdir -p /run/microvm-console && $SUDO chmod 777 /run/microvm-console
  cat > /tmp/vm-console.py <<'PY'
import socket, sys, os, select, termios, tty
QMP, CONSOLE = sys.argv[1], sys.argv[2]
def rl(s, t=6):
    s.settimeout(t); b = b""
    try:
        while b"\n" not in b:
            c = s.recv(65536)
            if not c: break
            b += c
    except Exception: pass
    return b.decode(errors="replace")
q = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); q.connect(QMP); rl(q)
q.send((b'{"execute":"qmp_capabilities"}\n')); rl(q)
def hmp(line):
    import json
    q.send((json.dumps({"execute":"human-monitor-command",
                        "arguments":{"command-line":line,"cpu-index":0}})+"\n").encode())
    return rl(q)
# QEMU 11: the 2nd argument is a backend DRIVER spec, not a chardev id. The
# serial device is anonymous so its `chardev` property can no longer be set
# after realize; re-pointing the `stdio` chardev it is wired to is what works.
print(hmp(f"chardev-change stdio socket,path={CONSOLE},server=on,wait=off").strip() or "console -> " + CONSOLE)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
for _ in range(40):
    try: s.connect(CONSOLE); break
    except OSError: import time; time.sleep(0.25)
else:
    sys.exit("could not connect to the console socket")
print("[attached; Ctrl-] to detach. Guest console output leaves the host journal while attached.]", file=sys.stderr)
old = termios.tcgetattr(sys.stdin); tty.setraw(sys.stdin)
try:
    while True:
        r, _, _ = select.select([s, sys.stdin], [], [], 0.5)
        for fd in r:
            if fd == s:
                d = s.recv(65536)
                if not d: sys.exit(0)
                os.write(1, d)
            else:
                d = os.read(0, 1024)
                if d == b"\x1d": sys.exit(0)
                s.sendall(d)
except (SystemExit, KeyboardInterrupt): pass
finally:
    termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old)
PY
  exec $SUDO env HOME=/root timeout 3600 nix shell nixpkgs#python3 --command \
    python3 /tmp/vm-console.py "$QMP" "$CONSOLE"
fi

hdr "1. route into the hackspace bridge"
if ip route show 10.3.0.0/16 | grep -q .; then
  ok "10.3.0.0/16 routed: $(ip route show 10.3.0.0/16 | head -1)"
else
  bad "no route for 10.3.0.0/16 — grafton-hackspace-client-routes.service did not install it"
  note "systemctl status grafton-hackspace-client-routes.service"
fi

hdr "2. the microVM"
state=$(systemctl is-active "microvm@$VM" 2>/dev/null)
if [ "$state" = active ]; then
  ok "microvm@$VM active since $(systemctl show "microvm@$VM" -p ActiveEnterTimestamp --value)"
  note "a rebuild that changes the VM config restarts it — and it reboots WITHOUT its tailscale state unless the tailscale-state volume exists"
else
  bad "microvm@$VM is $state"
fi
if systemctl is-active "microvm@$VM" >/dev/null 2>&1 && [ "$amroot" = 1 ]; then
  vmpid=$(systemctl show "microvm@$VM" -p MainPID --value)
  if [ -n "$vmpid" ] && [ "$vmpid" != 0 ] && \
     $SUDO tr '\0' '\n' < "/proc/$vmpid/cmdline" 2>/dev/null | grep -qE '^-drive$|virtio-blk'; then
    ok "VM has a disk (tailscale state can persist across restarts)"
  else
    bad "VM has NO disk — /var/lib/tailscale is RAM-only, every restart must re-register with the pre-auth key"
  fi
fi
if ping -c1 -W2 "$VM_IP" >/dev/null 2>&1; then
  ok "VM answers ping on $VM_IP"
else
  bad "VM does not answer ping on $VM_IP"
fi

hdr "3. the VM's tailscale session (the usual culprit)"
if vmrun true; then
  backend=$(vmrun 'tailscale status --json' | grep -o '"BackendState": "[A-Za-z]*"' | cut -d'"' -f4)
  case "$backend" in
    Running) ok "VM tailscaled BackendState=Running" ;;
    *)       bad "VM tailscaled is not Running: ${backend:-no state (tailscaled down?)}"
             note "vmrun is just ssh: ssh root@$VM_IP 'tailscale status; journalctl -u tailscaled -u hackspace-tailscale-ensure --since -1h'"
             # NeedsLogin is NOT usually a bad key. The hackspace's headscale can
             # delete this node under a healthy tunnel, and tailscaled treats
             # `404: node not found` exactly like a logout (2026-10-16 08:21 UTC).
             # hackspace-tailscale-ensure.service re-registers within a minute,
             # so a *stuck* NeedsLogin means the re-join itself is failing.
             note "why did it drop? last state change and control error:"
             vmrun "journalctl -u tailscaled --no-pager -o short-iso 2>/dev/null | grep -E 'Switching ipn state|active login|node not found|LocalAPI' | tail -3" | sed 's/^/       /'
             ;;
  esac
  [ "$(vmrun 'systemctl is-failed tailscaled-autoconnect')" = failed ] \
    && bad "tailscaled-autoconnect.service is failed (it exits on a rejected auth key and is never retried)"
  note "in-VM default route (a tailscale default route + a dead tunnel self-locks the VM):"
  vmrun 'ip route show default' | sed 's/^/       /'
else
  skip "cannot ssh root@$VM_IP - deploy the health key (sops: grafton_hackspace_client_ssh_key) or use --console"
fi

hdr "4. the tunnel itself"
if ping -c2 -W2 "$HACKSPACE_IP" >/dev/null 2>&1; then
  tunnel=up; ok "$HACKSPACE_IP answers ICMP over the tailnet"
elif timeout 5 bash -c "exec 3<>/dev/tcp/$HACKSPACE_IP/53" 2>/dev/null; then
  tunnel=up; ok "$HACKSPACE_IP:53 answers TCP (ICMP is filtered, tunnel is up)"
else
  tunnel=down; bad "$HACKSPACE_IP unreachable — no path to the leighhack tailnet"
fi
code=$(timeout 10 curl -sS -o /dev/null -w '%{http_code}' "$COORD/" 2>/dev/null)
if [ -n "$code" ] && [ "$code" != 000 ]; then
  ok "coordination server $COORD reachable from the host (HTTP $code)"
else
  bad "coordination server $COORD not reachable from the host — the hackspace's headscale may be the outage"
fi

hdr "5. is the tunnel one-way? (the 2026-10-14 failure)"
# From the host, "VM logged out" and "VM logged in but no return route" look
# identical. Ask the VM which one it is: if it can reach the hackspace side but
# we cannot, the return path is missing, and that is their headscale, not us.
if [ "${tunnel:-up}" = down ] && vmrun true; then
  backend=$(vmrun 'tailscale status --json' | grep -o '"BackendState": "[A-Za-z]*"' | cut -d'"' -f4)
  if vmrun "ping -c2 -W2 $HACKSPACE_IP >/dev/null 2>&1"; then inner=up; else inner=down; fi
  note "VM BackendState=${backend:-?}; VM's own reachability of $HACKSPACE_IP: $inner"
  note "routes the server has enabled for this node:"
  vmrun 'tailscale status --json' | tr -d ' \n' | sed 's/,"Peer".*//' \
    | grep -o '"PrimaryRoutes":\[[^]]*\]' | sed 's/^/       /'
  if [ "$backend" = Running ] && [ "$inner" = up ]; then
    bad "ONE-WAY TUNNEL: the VM reaches $HACKSPACE_IP but replies never come back"
    one_way=1
  fi
fi

hdr "6. downstream consumer (DNS)"
if timeout 8 getent hosts aibox.int.leighhack.org >/dev/null 2>&1; then
  ok "int.leighhack.org resolves: $(getent hosts aibox.int.leighhack.org | head -1)"
else
  bad "int.leighhack.org does not resolve (adguard forwards the zone to $HACKSPACE_IP:53)"
fi

hdr "verdict"
printf '  %d pass, %d fail, %d skip\n' "$pass" "$fail" "$skip"

if [ "${one_way:-0}" = 1 ]; then
  printf '\n  \033[31mONE-WAY TUNNEL\033[0m - not a login problem.\n'
  cat <<'EOF'

  The VM is logged in and reaches the hackspace, but replies never return, so
  grafton -> leighhack is black-holed. The VM advertises 192.168.49.0/24, and a
  FRESH registration starts with that route NOT enabled on their headscale, so
  services1 has no path back to us.

  FIX (their side): ask the hackspace admin to enable the subnet route for node
  grafton-hackspace-client, e.g.
      headscale routes enable -r 192.168.49.0/24 -n <node-id>
  or auto-approve it in their ACLs, so a re-registration cannot silently drop it.
EOF
  exit 1
fi

if [ "$fail" -eq 0 ]; then
  printf '  \033[32mthe leighhack path looks healthy\033[0m — if a specific service still fails, look above this path\n'
  exit 0
fi
cat <<'EOF'

  Next step depends on the first FAIL above:
    route    systemctl restart grafton-hackspace-client-routes
    vm       systemctl status microvm@grafton-hackspace-client
    session  the VM re-joins itself (hackspace-tailscale-ensure, 1 min). If it is
             still NeedsLogin the pre-auth key is spent/rejected/expired: read the
             reason above, put a new REUSABLE key in sops
             (leigh_hackspace_tailscale_pre_auth_key) and rebuild. Restarting the
             VM is not the fix and costs a fresh node on their headscale.
    tunnel   the VM is logged in but has no path — check the hackspace side
             (their headscale / DERP) before touching this host.
EOF
exit 1
