{
  config,
  pkgs,
  lib,
  ...
}:

{
  boot.kernel.sysctl = {
    # enable IPv4 forwarding on all interfaces
    "net.ipv4.conf.all.forwarding" = true;
    "net.ipv4.conf.all.arp_filter" = 1;
    "net.ipv4.conf.default.arp_filter" = 1;
  };

  networking = {
    networkmanager.enable = lib.mkForce false;
    useDHCP = false;
    useNetworkd = true;

    nftables.enable = true;
    firewall.enable = false;
  };

  systemd.network = {
    enable = true;
    wait-online.enable = false;

    links = {
      "10-lan" = {
        # Left side port
        matchConfig = {
          MACAddress = "00:e0:4d:02:cd:56";
        };
        linkConfig = {
          Name = "lan";
        };
      };

      "20-wan" = {
        # Right side port
        matchConfig = {
          MACAddress = "00:e0:4d:02:cd:57";
        };
        linkConfig = {
          Name = "wan";
        };
      };
    };

    networks = {
      "10-lan" = {
        matchConfig.Name = "lan";
        linkConfig.RequiredForOnline = "yes";
        networkConfig = {
          DHCP = false;
        };
        address = [
          "192.168.49.21/24"
        ];
        dns = [ "192.168.49.21" ];
        domains = [ "grafton.lan" ];
      };

      "20-wan" = {
        matchConfig.Name = "wan";
        linkConfig.RequiredForOnline = "no";
        networkConfig = {
          DHCP = true;
        };
      };
    };
  };

  environment.systemPackages = [ pkgs.dnsmasq ];

  # cat /var/lib/dnsmasq/dnsmasq.leases
  services.dnsmasq = {
    enable = true;
    resolveLocalQueries = false;
    settings = {
      # bind to 8053, we want adguard to provide DNS
      # and we'll let resolved own the loopback port 53
      port = 8053;
      no-resolv = true;
      bind-dynamic = true;
      dhcp-authoritative = true;
      domain-needed = true;
      enable-ra = true;

      addn-hosts = "${pkgs.writeText "service-hosts" ''
        192.168.49.21   router.grafton.lan
      ''}";

      domain = "grafton.lan";
      local = "/grafton.lan/";

      dhcp-range = [
        "set:lan,192.168.49.101,192.168.49.200,255.255.255.0,1h"
      ];
      dhcp-option = [
        "tag:lan,option:dns-server,192.168.49.21"
      ];
    };
  };

  networking.nftables.ruleset = ''
    table inet firewall {
      chain rpfilter {
        type filter hook prerouting priority mangle + 10; policy drop;
        meta nfproto ipv4 udp sport . udp dport { 68 . 67, 67 . 68 } accept comment "DHCPv4 client/server"
        fib saddr . mark oif exists accept
      }

      chain input {
        type filter hook input priority filter; policy drop;

        # assuming we trust our LAN clients
        iifname { "lo", "lan", "podman0" } accept comment "trusted interfaces"

        udp dport 5353 accept comment "mdns from anywhere"

        # handle packets according to connection state
        ct state vmap { invalid : drop, established : accept, related : accept, new : jump input-allow, untracked : jump input-allow }

        # if we make it here, block and log
        tcp flags syn / fin,syn,rst,ack log prefix "refused connection: " level info
      }

      chain input-allow {
        # make your own choice on whether to allow SSH from outside
        ip saddr 10.47.0.0/16    tcp dport 22 accept comment "ssh from VPN"
        ip saddr 192.168.49.0/24 tcp dport 22 accept comment "ssh from LAN"

        tcp dport 22 accept comment "http from anywhere"
        tcp dport 80 accept comment "http from anywhere"
        tcp dport 443 accept comment "https from anywhere"

        icmp type echo-request accept comment "allow ping"
      }

      chain forward {
        type filter hook forward priority 0; policy drop;

        udp dport 5353 accept comment "mdns from anywhere"

        # no internet egress to RFC1918 IPs
        oifname "wan" ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } reject with icmp type net-unreachable comment "outbound rfc1918 not permitted"

        # established/related allowed, invalid dropped
        ct state vmap { established : accept, related : accept, invalid : drop }

        # internal interfaces outbound allowed
        iifname "lan" oifname "wan" accept comment "internal networks out via ISP"
        iifname "podman0" oifname "wan" accept comment "Allow podman to internet"

        iifname "lan" oifname "podman0" accept comment "internal networks to podman"
        iifname "podman0" oifname "lan" accept comment "Allow podman to access LAN"

        # allow icmp
        icmp type echo-request accept comment "allow ping"

        # log anything that was blocked
        tcp flags syn / fin,syn,rst,ack log prefix "refused forward: " level info
      }

      chain output {
        type filter hook output priority 0; policy accept;
      }
    }

    table ip nat {
      chain pre {
        type nat hook prerouting priority dstnat; policy accept;
      }

      chain post {
        type nat hook postrouting priority srcnat; policy accept;

        iifname "lan" oifname "wan" masquerade comment "LAN NAT to WAN"
        iifname "podman0" oifname "wan" masquerade comment "Podman to WAN"
      }

      chain out {
        type nat hook output priority mangle; policy accept;
        # we'll add rules for our 1:1 NAT here later
      }
    }
  '';

  services.adguardhome = {
    enable = true;
    # any changes made through the web UI will be thrown away
    # on rebuild with this setting...
    mutableSettings = false;
    settings = {
      # note this configuration logs queries by default
      # check the docs if you want to avoid this

      # this will allow unauthenticated access to the adguard UI
      # to any host on your LAN.
      # Change it to 127.0.0.1 if you do not want this
      host = "192.168.49.21";

      dns = {
        bind_hosts = [
          # trusted lan
          "192.168.49.21"
        ];
        port = 53;
        # some optimisations I found necessary
        ratelimit = 0;
        cache_size = 67108864;
        max_goroutines = 500;
        use_http3_upstreams = true;
        upstream_dns = [
          # you may prefer to use your own ISPs DNS
          "https://dns.quad9.net/dns-query"
          "https://dns.mullvad.net/dns-query"
          "https://cloudflare-dns.com/dns-query"
          # requests for the local domain go to dnsmasq
          "[/grafton.lan/]127.0.0.1:8053"
        ];
        local_ptr_upstreams = [
          # reverse lookups for local IPs go to dnsmasq
          "127.0.0.1:8053"
        ];
        bootstrap_dns = [
          # you may prefer to use your own ISPs DNS
          "1.1.1.1"
          "8.8.8.8"
        ];
      };
    };
  };
}
