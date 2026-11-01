# Friend tunnel — share one /64 of the delegated /48 with a friend behind a
# web-traffic-only ISP (see networking/constants.nix for the layout).
#
#   internet ──▶ pppoe-zen ──▶ route f0::/64 via wg-friend ──▶ WireGuard
#                                                                       │ UDP
#   friend-router VM ── wstunnel client ── wss :443 ──▶ nginx (TLS, the
#   public edge's cert) ── ws 127.0.0.1:8087 ──▶ wstunnel server ──▶ UDP
#   127.0.0.1:51830 = wg-friend's listen port.
#
# The inner IPv6 never touches Zen's filters: from the ISP's side it is TCP
# payload on 443. Zen routes the whole /48 to this session (that is how
# :49::/64 is already globally reachable), so the friend's /64 rides in with
# no upstream work at all. Only the router side lives here; the client side
# (the friend's router) is the friend-router microVM in
# ../virtual-machines/friend-router.nix.
#
# Policy note: RIPE-738 says an assignment "is not to be sub-assigned to
# other parties", so delegating a routed /64 to a third party is not what we
# are authorised to do with Zen's /48 — treat this as an extended-LAN/
# point-to-point link instead. Fine for a friend; do not advertise it.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  c = import ../networking/constants.nix;
in
{
  # wg-friend over raw systemd-networkd, NOT the networking.wireguard module:
  # its useNetworkd switch is global and would move wg0 (the ovh link with
  # its cron-restart crutch) onto networkd mid-experiment.
  systemd.network.netdevs."40-wg-friend" = {
    netdevConfig = {
      Kind = "wireguard";
      Name = "wg-friend";
      # Comfortably under 1500 - WS - TLS - TCP - PPPoE - WG overhead; the
      # TCP-in-TCP tunnel punishes fragments, so start at the IPv6 minimum.
      MTUBytes = "1280";
    };
    wireguardConfig = {
      PrivateKeyFile = config.sops.secrets.friend_tunnel_wg_key.path;
      ListenPort = c.WG_FRIEND_PORT; # wstunnel re-delivers WG's UDP here
    };
    # The whole friend LAN (its devices address from the /64 themselves), so
    # replies to e.g. f0::10 pass the peer filter.
    wireguardPeers = [
      {
        PublicKey = c.FRIEND_ROUTER_WG_PUBKEY;
        AllowedIPs = [ c.FRIEND_V6_SUBNET ];
      }
    ];
  };

  systemd.network.networks."40-wg-friend" = {
    matchConfig.Name = "wg-friend";
    linkConfig.RequiredForOnline = "no"; # down until the friend dials in
    networkConfig.DHCP = "no";
    address = [ "${c.FRIEND_V6_ROUTER}/64" ];
  };

  # The WebSocket carrier. Plain ws on loopback: nginx terminates the TLS the
  # client actually speaks (wss :443), so wstunnel needs no certificate of
  # its own. --restrict-to means a client that knows the secret path still
  # cannot open tunnels to anywhere except our own WireGuard port.
  systemd.services.wstunnel-server = {
    description = "wstunnel WebSocket carrier for the friend WireGuard tunnel";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      ExecStart = ''
        ${lib.getExe pkgs.wstunnel} server \
          ws://127.0.0.1:${toString c.WSTUNNEL_PORT} \
          --restrict-to 127.0.0.1:${toString c.WG_FRIEND_PORT} \
          --restrict-http-upgrade-path-prefix ${c.FRIEND_TUNNEL_WS_PREFIX} \
          --websocket-ping-frequency 20s
      '';
      Restart = "always";
      RestartSec = 5;
      DynamicUser = true;
      NoNewPrivileges = true;
    };
  };

  # Public edge: $FRIEND_TUNNEL_HOST is fronted by the existing wildcard cert
  # ("chrisdell.info" covers *.home.chrisdell.info), and the only thing it
  # serves is the wstunnel upgrade under the secret path prefix. The VM dials
  # it via an /etc/hosts entry (2a02:8010:6680:49::1); a real deployment adds
  # the AAAA to Route53 like every other *.home name.
  services.nginx.virtualHosts.${c.FRIEND_TUNNEL_HOST} = {
    useACMEHost = "chrisdell.info";
    forceSSL = true;
    locations."/".extraConfig = ''
      return 404;
    '';
    locations."/${c.FRIEND_TUNNEL_WS_PREFIX}/" = {
      proxyPass = "http://127.0.0.1:${toString c.WSTUNNEL_PORT}";
      proxyWebsockets = true;
      # A tunnel, not a web page: never idle a live connection, never buffer.
      extraConfig = ''
        proxy_read_timeout 7d;
        proxy_send_timeout 7d;
        proxy_buffering off;
      '';
    };
  };
}
