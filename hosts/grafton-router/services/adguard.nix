let
  net = import ../networking/constants.nix;
  mkSSOVirtualHost = import ../../../utils/nginx-sso-helper.nix;
in
{
  services.adguardhome = {
    enable = true;
    # Any changes made through the web UI will be thrown away
    mutableSettings = false;
    # Admin UI port
    port = 8153;
    settings = {
      # Admin UI listen address (NGINX proxies this)
      host = "127.0.0.1";

      # Split DNS for internal network services. Allows things to still work without internet access.
      user_rules = [
        "${net.LAN_IPV4} router.home.chrisdell.info"
        "${net.LAN_IPV4} notify.home.chrisdell.info"

        "@@||google-analytics.com^"
        "@@||google.com^"
        "@@||doubleclick.net^"
      ];

      dns = {
        bind_hosts = [
          net.LAN_IPV4
          net.VLAN10_IPV4
          net.LAN_IPV6_ADDRESS
        ];

        port = net.DNS_PORT;
        # some optimisations I found necessary
        ratelimit = 0;
        cache_size = 67108864;
        max_goroutines = 500;
        # DoH3 (HTTP/3) upstream connections wedge: dnsproxy keeps reusing a
        # stale QUIC connection and every query on it fails with
        # "Get_0rtt ... timeout: no recent network activity" for 10-30s
        # (AdGuardHome#6937/#7390, dnsproxy#461). On 2026-10-02 the Quad9 H3
        # upstream hung for hours and load_balance kept picking it, so LAN
        # lookups stalled until the client gave up (llama.ai.chrisdell.info,
        # api.deepseek.com). Use DoH over HTTP/2, and query all upstreams in
        # parallel so one stalled upstream cannot add its full upstream_timeout
        # to every lookup.
        use_http3_upstreams = false;
        upstream_mode = "parallel";

        upstream_dns = [
          "https://dns.quad9.net/dns-query"
          "https://dns.mullvad.net/dns-query"
          "https://cloudflare-dns.com/dns-query"
          # Requests for the local domain go to dnsmasq
          "[/grafton.lan/]127.0.0.1:8053"
          "[/int.leighhack.org/]10.3.1.1:53"
          "[/grafton.tailscale/]100.100.100.100:53"
        ];
        local_ptr_upstreams = [
          # Reverse lookups for local IPs go to dnsmasq
          "127.0.0.1:8053"
        ];
        bootstrap_dns = [
          "9.9.9.9"
          "1.1.1.1"
          "8.8.8.8"
        ];
      };
    };
  };

  services.nginx.virtualHosts = {
    "adguard.home.chrisdell.info" = mkSSOVirtualHost {
      proxyPass = "http://127.0.0.1:8153";
    };
  };
}
