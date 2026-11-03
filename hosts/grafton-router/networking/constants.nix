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

  # LAN's /64 slice of the delegated prefix (subnet-id 0x49)
  LAN_IPV6_PREFIX = "2a02:8010:6680:49::";
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
  DELEGATED_PREFIX = "2a02:8010:6680::/48"; # IPv6 delegated by Zen (PPPoE)
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
  FRIEND_V6_SUBNET = "2a02:8010:6680:f0::/64"; # the shared /64 from our /48
  FRIEND_V6_ROUTER = "2a02:8010:6680:f0::1"; # wg-friend on the router
  FRIEND_V6_VM = "2a02:8010:6680:f0::2"; # wg-friend on the friend VM
  # br-friend (the friend's LAN) needs its own global address, distinct from
  # the two tunnel ends: networkd only sends router advertisements from a
  # link that has a static IPv6 address configured.
  FRIEND_V6_LAN = "2a02:8010:6680:f0::9"; # friend-router LAN gateway on br-friend
  FRIEND_V6_DEV = "2a02:8010:6680:f0::10"; # static token addr on the VM's demo device
  WSTUNNEL_PORT = 8087; # wstunnel server, loopback only (nginx fronts it on 443)
  WG_FRIEND_PORT = 51830; # wg-friend's listen port (51820 is wg0's)
  FRIEND_TUNNEL_HOST = "homerail.home.chrisdell.info"; # edge name the client dials (wildcard cert covers it)
  # Shared-secret WebSocket upgrade path. NOT the auth story (WG keys are);
  # it just keeps random wstunnel clients off the endpoint. Committed on
  # purpose: nginx `location` cannot read a sops value at runtime.
  FRIEND_TUNNEL_WS_PREFIX = "hrx9KqL2tWm4Zd7VbN";

  # Public halves of the wg-friend keypair. The private halves are sops
  # secrets friend_tunnel_wg_key (router) and friend_router_wg_key (VM).
  FRIEND_TUNNEL_WG_PUBKEY = "P3SQVFg2RFF0e3YDbrKwJLrHiV2Z65U9Bap5YpW9gDA=";
  FRIEND_ROUTER_WG_PUBKEY = "dVV0xEAiDqiYW3oatJ5oTKQP5aDADXYUWDoSvY4qoCk=";
}
