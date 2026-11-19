# Shared networking constants for the Grafton router.
#
# Single source of truth for the network layout: interface names, addresses,
# subnets, ports and DNS/DHCP settings. Import this anywhere the same value
# would otherwise be typed out twice (firewall, dnsmasq, AdGuard, networkd).
rec {
  # ---------------------------------------------------------------------------
  # Interfaces
  # ---------------------------------------------------------------------------
  WAN_INTERFACE = "pppoe-zen"; # PPPoE uplink to Zen (created by pppd)
  LAN_INTERFACE = "lan"; # bridge for the LAN + VMs
  VLAN10_INTERFACE = "vlan10"; # experimental VLAN
  PODMAN_INTERFACE = "podman0"; # podman default-network bridge
  TAILSCALE_INTERFACE = "tailscale0";

  # ---------------------------------------------------------------------------
  # Router addresses
  # ---------------------------------------------------------------------------
  LAN_IPV4 = "192.168.49.1"; # router on lan (192.168.49.1/24)
  VLAN10_IPV4 = "192.168.10.1"; # router on vlan10 (192.168.10.1/24)

  # LAN's /64 slice of the delegated prefix (subnet-id 0x49).
  # ⚠️ Self-expiring credential — the ISP owns this prefix. Before ever
  # re-pinning it, verify the LIVE delegation from THREE sources, because a
  # WAN SLAAC address is NOT one: `journalctl -u systemd-networkd | grep
  # 'received delegated prefix'` (authoritative — ours was still
  # 2a02:8010:6680::/48 at the 2026-11-19 re-solicit even while a handover
  # note was certain Zen had moved us to 2a02:8011:d000::/48; that /48 was
  # actually read off Zen's access-link /64 2a02:8011:d000:672::, which the
  # WAN interface has had for weeks), the ISP's own account/dashboard, and a
  # source-bound ping (`ping -6 -I <addr-in-candidate-prefix> 2606:4700:4700::1111`)
  # proving it routes BOTH ways. Getting this wrong black-holes the house v6:
  # firewall.nix forwards only `ip6 saddr DELEGATED_PREFIX`. Sweep the pin
  # list together: the static v6 reservations in dns.nix, the pg_hba lines
  # (this host + N100-NAS), lfm3's nginx allow row in hosts/zen3-nixos/, the
  # FRIEND_V6_* slices (the friend's wg config embeds the /64), and the
  # Route 53 AAAA records (external — nothing in this repo moves them).
  LAN_IPV6_PREFIX = "2a02:8010:6680:49::";
  LAN_IPV6_SUBNET = "${LAN_IPV6_PREFIX}/64"; # what LAN clients present as their source
  LAN_IPV6_ADDRESS = "${LAN_IPV6_PREFIX}1"; # router on lan (…:49::1/64)

  # ---------------------------------------------------------------------------
  # Subnets
  # ---------------------------------------------------------------------------
  LAN_SUBNET = "192.168.49.0/24";
  VLAN10_SUBNET = "192.168.10.0/24";
  PODMAN_SUBNET = "192.168.100.0/24"; # podman containers
  WIREGUARD_SUBNET = "10.47.0.0/16"; # wg0 tunnel
  TAILSCALE_SUBNET = "100.64.0.0/10"; # headscale ip_prefixes (CGNAT)
  HACKSPACE_SUBNET = "10.3.0.0/16"; # via grafton-hackspace-client VM
  GATLING_SUBNET = "10.0.1.0/24"; # gatling-services' tailnet subnet route
  # Hackspace public IPv6 — trusted; full access to the LANs from the internet
  HACKSPACE_IPV6_SUBNET = "2001:8b0:1d14::/48";
  # ...and the ULA the same *.int names hand out with it. Also advertised by
  # gw-1 on the leighhack tailnet, so it, too, belongs on the VM route.
  HACKSPACE_ULA_SUBNET = "fd99:dead:beef::/48";
  DELEGATED_PREFIX = "2a02:8010:6680::/48"; # IPv6 delegated by Zen (PPPoE); see LAN_IPV6_PREFIX
  DBTHR33_SUBNET = "2a0a:ef40:241::/48";
  # dbthr33-server's network — trusted
  # so its direct WireGuard/NAS traffic
  # is accepted (see tailscale-slow.md)

  # ---------------------------------------------------------------------------
  # Service ports
  # ---------------------------------------------------------------------------
  SSH_PORT = 22;
  HTTP_PORT = 80;
  HTTPS_PORT = 443;
  STUN_PORT = 3479; # headscale DERP STUN
  TAILSCALE_PORT = 41641; # tailscale wireguard (all nodes)
  MDNS_PORT = 5353;
  HOME_ASSISTANT_PORT = 8123; # Home Assistant (host-network container)

  # ---------------------------------------------------------------------------
  # DNS
  # ---------------------------------------------------------------------------
  # AdGuard answers LAN clients on :53; dnsmasq owns the grafton.lan zone (and
  # DHCP) on :8053 and is an upstream of AdGuard.
  DNS_PORT = 53;
  DNSMASQ_PORT = 8053;

  # ---------------------------------------------------------------------------
  # DHCP (dnsmasq)
  # ---------------------------------------------------------------------------
  DHCPV4_CLIENT_PORT = 68; # bootpc
  DHCPV4_SERVER_PORT = 67; # bootps
  DHCPV6_CLIENT_PORT = 546; # router as DHCPv6 client (PD)
  DHCPV6_SERVER_PORT = 547; # ISP's DHCPv6 server / dnsmasq

  LAN_DHCP_V4_RANGE = "192.168.49.101,192.168.49.200";
  VLAN10_DHCP_V4_RANGE = "192.168.10.101,192.168.10.200";
  DHCP_LEASE_TIME = "1h";

  # ---------------------------------------------------------------------------
  # Friend tunnel experiment (services/friend-tunnel.nix + the friend-router
  # microVM). Sharing one /64 of our delegated /48 with a friend behind a
  # strict, web-traffic-only ISP: WireGuard rides a UDP tunnel inside a
  # WebSocket to $FRIEND_TUNNEL_HOST, which nginx proxies to the wstunnel
  # server on loopback. The microVM sits on $STRICT_INTERFACE, a bridge whose
  # only transit allowance is TCP/443 — the simulated strict ISP.
  # ---------------------------------------------------------------------------
  STRICT_INTERFACE = "br-strict"; # simulated strict-ISP link to the friend VM
  STRICT_IPV4 = "192.168.99.1"; # router side of the strict link
  STRICT_SUBNET = "192.168.99.0/24";
  FRIEND_ROUTER_IP = "192.168.99.2"; # friend-router VM "WAN" (v4, NATed)
  # Subnet id 0x8472 of Zen's /48; :49: is the LAN, :10: is VLAN10 (PD). Any
  # /64 inside the /48 works — Zen routes the whole /48 to this session and the
  # router blackholes it on lo, so a new slice needs no upstream change.
  # They pin the delegation, so if it ever *really* changes (verify per the
  # LAN_IPV6_PREFIX comment) these move with it — and the friend's wg config
  # embeds the old slice, so he needs the new /64 too
  # (docs/friend-ipv6-over-websocket.md).
  FRIEND_V6_SUBNET = "2a02:8010:6680:8472::/64"; # the shared /64 from our /48
  FRIEND_V6_ROUTER = "2a02:8010:6680:8472::1"; # wg-friend on the router
  FRIEND_V6_VM = "2a02:8010:6680:8472::2"; # wg-friend on the friend VM
  # br-friend (the friend's LAN) needs its own global address, distinct from
  # the two tunnel ends: networkd only sends router advertisements from a
  # link that has a static IPv6 address configured.
  FRIEND_V6_LAN = "2a02:8010:6680:8472::9"; # friend-router LAN gateway on br-friend
  FRIEND_V6_DEV = "2a02:8010:6680:8472::10"; # static token addr on the VM's demo device
  WSTUNNEL_PORT = 8087; # wstunnel server, loopback only (nginx fronts it on 443)
  WG_FRIEND_INTERFACE = "wg-friend"; # the tunnel interface on the router
  WG_FRIEND_PORT = 51830; # wg-friend's listen port (51820 is wg0's)
  FRIEND_TUNNEL_HOST = "homerail.home.chrisdell.info"; # edge name the client dials (wildcard cert covers it)
  # LAN-only status page: live log of his successful/failed connection attempts
  # (rendered by services/friend-tunnel-log.nix, nginx allow-lists LAN_SUBNET).
  FRIEND_TUNNEL_LOG_HOST = "tunnel-log.home.chrisdell.info";
  # Shared-secret WebSocket upgrade path. NOT the auth story (WG keys are);
  # it just keeps random wstunnel clients off the endpoint. Committed on
  # purpose: nginx `location` cannot read a sops value at runtime.
  FRIEND_TUNNEL_WS_PREFIX = "hrx9KqL2tWm4Zd7VbN";

  # Public halves of the wg-friend keypair. The router's private half is the
  # sops secret friend_tunnel_wg_key.
  FRIEND_TUNNEL_WG_PUBKEY = "P3SQVFg2RFF0e3YDbrKwJLrHiV2Z65U9Bap5YpW9gDA=";
  # The live peer: a pre-generated keypair handed to the friend in his setup
  # guide (its private half lives in the gitignored docs/friend-ipv6-over-websocket.md),
  # so he can build without waiting on a round trip. The peer before him was the
  # demo VM (sops friend_router_wg_key, pubkey
  # dVV0xEAiDqiYW3oatJ5oTKQP5aDADXYUWDoSvY4qoCk=), now parked: one /64 carries
  # exactly one peer, because AllowedIPs also authorise a received packet's
  # INNER source address — two peers on one /64 can each legitimately claim any
  # address in it, which turns the pair into a mutual blackhole/MITM pair.
  # To revive the demo, give it its own /64 and swap this value back.
  FRIEND_ROUTER_WG_PUBKEY = "oRzdjrO+QZkPXPmbFMsmBd0q0jYS9vh7mRNuZvnC1AI=";
}
