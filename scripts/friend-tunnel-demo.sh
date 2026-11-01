#!/usr/bin/env bash
# friend-tunnel demo: evidence the /64-over-WebSocket experiment works.
# Run ON grafton-router. Sections 1-3: plumbing, 4: the strict ISP bites,
# 5-7: friend-side v6 rides the tunnel, 8: inbound through the /64.
set -u
OUT=${1:-/tmp/friend-demo.out}
exec > "$OUT" 2>&1
VM="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 root@192.168.99.2"
WG="nix shell nixpkgs#wireguard-tools --command wg"

echo "### 1. router-side units & links"
systemctl is-active wstunnel-server friend-router-secrets microvm@friend-router nginx
ip -br addr show br-strict; ip -br addr show wg-friend; ip -6 route show 2a02:8010:6680:f0::/64

echo; echo "### 2. WireGuard state (router end)"
sudo nix shell nixpkgs#wireguard-tools --command wg show wg-friend

echo; echo "### 3. VM: tunnel chain up?"
$VM 'systemctl is-active wstunnel-client; ip -6 route show default | head -2; wg show | grep -E "interface|latest|transfer"'

echo; echo "### 4. the strict ISP: only TCP/443 leaves, everything else refused"
echo "-- allowed: TCP/443 transit (note the CG-NATed source as seen by the net):"
$VM 'timeout 10 curl -sk4 --max-time 8 https://1.1.1.1/cdn-cgi/trace | grep -E "^ip=" || echo FAILED'
echo "-- refused: TCP/80 transit (icmpx admin-prohibited):"
$VM 'timeout 8 curl -s --max-time 6 -o /dev/null http://93.184.216.34/ 2>&1; echo "curl rc=$?"'
echo "-- refused: ICMP transit:"
$VM 'timeout 6 ping -c1 -W2 1.1.1.1 2>&1 | tail -2'
echo "-- absent: IPv6 on the ISP link itself (ext0 has no global address, no RA route):"
$VM 'ip -6 addr show dev ext0 scope global | grep -c inet6; ip -6 route show | grep "dev ext0" | grep -v fe80 | wc -l; echo "(0 + 0 = the ISP gives us no v6 at all; every v6 packet below rides the tunnel)"'

echo; echo "### 5. friend IPv6 egress rides the tunnel (source must be f0::/64)"
$VM 'timeout 12 curl -s6 --max-time 10 https://ifconfig.co/json | grep -E "ip|ip_version" | head -4'

echo; echo "### 6. DNS through the tunnel (RA RDNSS -> AdGuard 2a02:8010:6680:49::1)"
echo "-- any HTTP reply code (even a 403 from the app itself) proves the full
-- v6 + TLS + HTTP chain rode the wss:443 tunnel"
$VM 'resolvectl status 2>/dev/null | grep -A2 "Global:" | head -3; getent ahostsv6 logs.ai.chrisdell.info | head -1; timeout 10 curl -s6 --max-time 8 -o /dev/null -w "https://logs.ai.chrisdell.info -> HTTP %{http_code}\n" https://logs.ai.chrisdell.info/'

echo; echo "### 7. RA carries the /64 onto the friend LAN (Router Solicitation on br-friend)"
$VM 'timeout 8 rdisc6 -r 1 -w 3500 br-friend 2>&1 | head -18; echo "-- fdev0 global addresses (static token ::10 + SLAAC from the RA):"; ip -6 addr show dev fdev0 scope global'

echo; echo "### 8. inbound: web server on the friend LAN reached via the shared /64"
echo "-- served by the VM itself:"
$VM 'curl -s --max-time 5 -o /dev/null -w "  local:    HTTP %{http_code}\n" http://[2a02:8010:6680:f0::10]/'
echo "-- from zen3 (LAN -> route f0::/64 -> wg-friend -> tunnel -> fdev0):"
ssh -o BatchMode=yes -o ConnectTimeout=6 cjdell@192.168.49.50 'curl -6 -s --max-time 8 -o /dev/null -w "  zen3:     HTTP %{http_code}\n" http://[2a02:8010:6680:f0::10]/'
echo "-- body as zen3 sees it:"
ssh -o BatchMode=yes -o ConnectTimeout=6 cjdell@192.168.49.50 'curl -6 -s --max-time 8 http://[2a02:8010:6680:f0::10]/ | head -c 300; echo'
echo; echo "### done"
