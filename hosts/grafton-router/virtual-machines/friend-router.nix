# friend-router — the CLIENT half of the friend-tunnel experiment
# (services/friend-tunnel.nix on the host carries the whole story).
#
# The microVM plays two roles at once:
#   * a friend's dual-NATed, web-only-connected home: its uplink (ext0) hangs
#     off the br-strict bridge, whose transit rules allow nothing but TCP/443
#     and whose v4 is masqueraded like CGNAT; it has no IPv6 route at all.
#   * the friend's router: wstunnel + WireGuard up to grafton-router, then it
#     hands the shared /64 out via router advertisements on its own LAN
#     (br-friend), exactly like a delegated-prefix ISP uplink would.
#
# A veth pair fdev0/fhost0 hangs off br-friend as a "device on his LAN":
# fdev0 SLAACs a global address from the /64 and carries a static token
# address, and a tiny python web server answers inbound requests from the
# public internet — the proof both directions work.
#
#   zen3 / internet ──▶ 2a02:8010:6680:f0::/64 ─▶ router wg-friend
#     ─▶ (WG over UDP-over-wss-over-443) ─▶ VM wg-friend ─▶ br-friend ─▶ fdev0
{
  config,
  lib,
  pkgs,
  ...
}:
let
  c = import ../networking/constants.nix;
  guestConstants = c; # the guest uses the same constants as the host

  vmSecretShare = "/run/vm-secrets/friend-router";

  # Same copy-not-mount discipline as grafton-hackspace-client: virtiofsd
  # keeps the directory inode it opened at VM start, so this stays a plain
  # directory refreshed in place, never a mount.
  # friend_router_wg_key additionally gets group systemd-network 0440: the
  # GUEST's systemd-networkd reads it as PrivateKeyFile for its wg-friend
  # netdev, and virtiofs carries uids straight through — the guest's
  # systemd-network group has the same numeric id as ours (this nixpkgs: 152).
  publishVmSecrets = ''
    ${pkgs.coreutils}/bin/mkdir -p ${vmSecretShare}
    ${pkgs.coreutils}/bin/install -m 0440 -g systemd-network ${config.sops.secrets.friend_router_wg_key.path} ${vmSecretShare}/friend_router_wg_key
    ${pkgs.coreutils}/bin/install -m 0400 ${config.sops.secrets.friend_vm_host_key.path} ${vmSecretShare}/friend_vm_host_key
  '';

  demoWebRoot = pkgs.writeTextDir "index.html" ''
    <!doctype html><h1>friend-router</h1>
    <p>You reached a web server on the friend's LAN (veth device fdev0) via a
    /64 shared from grafton-router's delegated prefix, over a WireGuard
    tunnel riding a WebSocket to survive a web-traffic-only ISP.</p>
  '';

  # "friend's LAN device": create it, SLAAC it from the RA, pin resolv to the
  # tunnel. Not networkd-managed on purpose — networkd would own accept_ra
  # and the RDNSS plumbing we want to drive from one script.
  friendLanDevice = pkgs.writeShellScript "friend-lan-device" ''
    set -u
    IP=${lib.getExe' pkgs.iproute2 "ip"}

    # wait for the LAN bridge to exist (networkd)
    for i in $(seq 1 60); do [ -e /sys/class/net/br-friend ] && break; sleep 1; done
    [ -e /sys/class/net/br-friend ] || { echo "br-friend never appeared"; exit 1; }

    if [ ! -e /sys/class/net/fdev0 ]; then
      $IP link add fdev0 type veth peer name fhost0
    fi
    $IP link set fhost0 master br-friend
    $IP link set fhost0 up
    $IP link set fdev0 up

    # The VM is a router (forwarding=1), so plain accept_ra would ignore RAs:
    # 2 = accept even while forwarding. Keep the default route off this port
    # anyway — the tunnel owns the default — but still SLAAC an address.
    # Asserted twice: networkd touches the freshly-created link's defaults as
    # its own event processing lands, and whichever writes last wins.
    set_ra() {
      echo 2 > /proc/sys/net/ipv6/conf/fdev0/accept_ra
      echo 0 > /proc/sys/net/ipv6/conf/fdev0/accept_ra_defrtr
    }
    set_ra
    sleep 3
    set_ra
    echo "fdev0 accept_ra=$(cat /proc/sys/net/ipv6/conf/fdev0/accept_ra)"

    # static token address (deterministic demo URL); a real device keeps
    # whatever SLAAC/DHCPv6 hands out alongside it.
    $IP -6 addr replace ${guestConstants.FRIEND_V6_DEV}/64 dev fdev0
    echo "friend-lan-device ready on fdev0"
  '';
in
{
  # Host side: keep the VM's two secret files published before virtiofsd
  # opens the share (the grafton-hackspace-client pattern).
  system.activationScripts.publish-friend-router-secrets = lib.stringAfter [
    "setupSecrets"
  ] publishVmSecrets;

  systemd.services.friend-router-secrets = {
    description = "Publish friend-router's secrets into its virtiofs share";
    wantedBy = [ "multi-user.target" ];
    requiredBy = [ "microvm-virtiofsd@friend-router.service" ];
    before = [ "microvm-virtiofsd@friend-router.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = publishVmSecrets;
  };

  microvm.vms.friend-router = {
    inherit pkgs;
    autostart = true;

    config = {
      microvm = {
        mem = 512;
        vcpu = 1;

        shares = [
          {
            source = "/nix/store";
            mountPoint = "/nix/.ro-store";
            tag = "ro-store";
            proto = "virtiofs";
          }
          {
            source = vmSecretShare;
            mountPoint = "/run/secrets";
            tag = "secrets";
            proto = "virtiofs";
            readOnly = true;
          }
        ];

        # rs-friend-up: the "ISP" side. NOT named vm-* — the host's lan
        # bridge enslaves vm-*; networking/interface.nix puts rs-friend-up
        # on br-strict instead. rs-friend-lan: br-friend's only member, so
        # the bridge has carrier without it (taps are up by creation).
        interfaces = [
          {
            type = "tap";
            id = "rs-friend-up";
            mac = "02:00:00:00:00:91";
          }
          {
            type = "tap";
            id = "rs-friend-lan";
            mac = "02:00:00:00:00:92";
          }
        ];
      };

      networking = {
        hostName = "friend-router";
        useDHCP = false;
        useNetworkd = true;
        nftables.enable = true;
        firewall.enable = false;

        # The strict-ISP link is IPv4-only — CGNAT, no public anything. So the
        # wss dial goes to the router's br-strict IPv4 (nginx matches the
        # vhost on SNI; the wildcard cert matches the name), and an
        # /etc/hosts entry means no DNS is needed on that link at all — the
        # same posture the real strict ISP leaves the friend in. The
        # production-shaped upgrade is the Route53 AAAA like every other
        # *.home name plus v6 from the ISP.
        hosts = {
          "${guestConstants.STRICT_IPV4}" = [ guestConstants.FRIEND_TUNNEL_HOST ];
        };
      };

      systemd.network.wait-online.enable = false;

      boot.kernel.sysctl = {
        "net.ipv4.conf.all.forwarding" = true;
        "net.ipv6.conf.all.forwarding" = true;
      };

      # Rename the two NICs by MAC (order-proof), then build:
      #   ext0 ─ "WAN"   192.168.99.2/24 via 192.168.99.1, v6 off
      #   lan0 ──▶ bridge br-friend (RA-sends the shared /64)
      #   wg-friend ──▶ the tunnel; ::/0 so ALL friend v6 rides it
      systemd.network = {
        links = {
          "10-ext" = {
            matchConfig.MACAddress = "02:00:00:00:00:91";
            linkConfig.Name = "ext0";
          };
          "20-lan" = {
            matchConfig.MACAddress = "02:00:00:00:00:92";
            linkConfig.Name = "lan0";
          };
        };

        netdevs = {
          "50-br-friend" = {
            netdevConfig = {
              Kind = "bridge";
              Name = "br-friend";
            };
          };
          "40-wg-friend" = {
            netdevConfig = {
              Kind = "wireguard";
              Name = "wg-friend";
              MTUBytes = "1280"; # must match the router end
            };
            wireguardConfig.PrivateKeyFile = "/run/secrets/friend_router_wg_key";
            wireguardPeers = [
              {
                PublicKey = guestConstants.FRIEND_TUNNEL_WG_PUBKEY;
                # The wstunnel client presents THIS VM's local UDP socket to
                # grafton's WireGuard port, so from inside the VM the tunnel
                # server is loopback. ::/0 = every friend-side v6 rides it.
                Endpoint = "127.0.0.1:${toString guestConstants.WG_FRIEND_PORT}";
                AllowedIPs = [ "::/0" ];
                PersistentKeepalive = 25;
              }
            ];
          };
        };

        networks = {
          "10-ext0" = {
            matchConfig.Name = "ext0";
            networkConfig = {
              DHCP = "no";
              IPv6AcceptRA = false; # the ISP gives us v4 only
            };
            address = [ "${guestConstants.FRIEND_ROUTER_IP}/24" ];
            routes = [
              {
                Gateway = guestConstants.STRICT_IPV4;
              }
            ];
          };

          "20-lan0" = {
            matchConfig.Name = "lan0";
            networkConfig.Bridge = "br-friend";
          };

          # RA the shared /64 onto the friend's LAN, with RDNSS — the
          # same networkd mechanism the router itself uses for :49::/64.
          # The static address is not cosmetic: networkd refuses to send
          # any RA from a link without one (silently, at trace level).
          "30-br-friend" = {
            matchConfig.Name = "br-friend";
            networkConfig = {
              IPv6SendRA = true;
              DHCP = "no";
            };
            address = [ "${guestConstants.FRIEND_V6_LAN}/64" ];
            ipv6SendRAConfig = {
              EmitDNS = true;
              DNS = guestConstants.LAN_IPV6_ADDRESS;
            };
            ipv6Prefixes = [
              {
                Prefix = guestConstants.FRIEND_V6_SUBNET;
                OnLink = true;
              }
            ];
          };

          # AllowedIPs routes are NOT installed by the netdev alone (that is
          # wg-quick/iproute2's job), so ::/0 over the tunnel is declared
          # explicitly — every friend-side v6 destination rides wstunnel.
          "40-wg-friend" = {
            matchConfig.Name = "wg-friend";
            linkConfig.RequiredForOnline = "no";
            networkConfig.DHCP = "no";
            address = [ "${guestConstants.FRIEND_V6_VM}/64" ];
            routes = [
              {
                Destination = "::/0";
                PreferredSource = guestConstants.FRIEND_V6_VM;
              }
            ];
          };
        };
      };

      # The WebSocket carrier leg: a single long-lived UDP flow
      # (127.0.0.1:51830 -> grafton's wg-friend) inside wss://…:443.
      # timeout_sec=0 is mandatory or wstunnel reaps the idle WG flow at
      # 30 s; pings keep NAT and the ISP's "web connection" state warm.
      # Literal-IP dial because the strict link deliberately has no DNS.
      # The SNI override names the vhost for the TLS handshake, but nginx
      # routes on the Host header FIRST — without the -H the dial arrives as
      # `Host: 192.168.99.1`, falls to the default vhost (2FAuth) and its
      # cheerful `200 OK` is what the client reports as
      # `Invalid status code: 200`. SNI + Host must agree (same trap the
      # --tls-sni-override help warns about for CDNs).
      systemd.services.wstunnel-client = {
        description = "Friend tunnel WebSocket carrier (wstunnel client)";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        serviceConfig = {
          ExecStart = ''
            ${lib.getExe pkgs.wstunnel} client \
              -L 'udp://127.0.0.1:${toString guestConstants.WG_FRIEND_PORT}:127.0.0.1:${toString guestConstants.WG_FRIEND_PORT}?timeout_sec=0' \
              --http-upgrade-path-prefix ${guestConstants.FRIEND_TUNNEL_WS_PREFIX} \
              -H 'host: ${guestConstants.FRIEND_TUNNEL_HOST}' \
              --tls-sni-override ${guestConstants.FRIEND_TUNNEL_HOST} \
              --websocket-ping-frequency 20s \
              wss://${guestConstants.STRICT_IPV4}
          '';
          Restart = "always";
          RestartSec = 5;
        };
      };

      systemd.services.friend-lan-device = {
        description = "Friend LAN demo device (fdev0) + resolved via tunnel";
        wantedBy = [ "multi-user.target" ];
        after = [
          "systemd-networkd.service"
          "systemd-resolved.service"
        ];
        wants = [ "systemd-resolved.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = friendLanDevice;
          Restart = "on-failure";
          RestartSec = 10;
        };
      };

      # Inbound half of the demo: curl http://[2a02:8010:6680:f0::10]/ from
      # the internet side and this answers.
      systemd.services.friend-demo-web = {
        description = "Friend LAN demo web server (python http.server)";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = ''
            ${pkgs.python3}/bin/python3 -m http.server 80 \
              --bind :: --directory ${demoWebRoot}
          '';
          Restart = "always";
          RestartSec = 3;
        };
      };

      # resolved has no per-link DNS anywhere in this guest (fdev0 is
      # deliberately unmanaged), so the global server is the tunnel path:
      # AdGuard at :49::1, reached through wg-friend. `resolvectl dns
      # global` is not a thing on this systemd — it wants the setting.
      services.resolved = {
        enable = true;
        settings.Resolve = {
          DNS = guestConstants.LAN_IPV6_ADDRESS;
          Domains = [ "~." ];
        };
      };

      services.openssh = {
        enable = true;
        settings.PermitRootLogin = "prohibit-password";
        hostKeys = [
          {
            bits = 256;
            path = "/var/secrets/ssh_host_ed25519_key";
            type = "ed25519";
          }
        ];
      };

      users.users.root.openssh.authorizedKeys.keys =
        config.users.users.cjdell.openssh.authorizedKeys.keys;

      # Root is a tmpfs every boot; decode the (base64-to-keep-it-one-line)
      # sops host key into place before sshd starts.
      system.activationScripts.friend-vm-host-key = ''
        mkdir -p /var/secrets
        ${pkgs.coreutils}/bin/base64 -d /run/secrets/friend_vm_host_key \
          > /var/secrets/ssh_host_ed25519_key
        ${pkgs.coreutils}/bin/chmod 0400 /var/secrets/ssh_host_ed25519_key
      '';

      environment.systemPackages = with pkgs; [
        bind # dig / nslookup
        curl
        iputils # ping / ping6
        ndisc6 # rdisc6: watch the RA carry the /64
        python3
        tcpdump
        wireguard-tools
      ];

      # Mirror the other microVM guest: nothing filters inside; the host's
      # br-strict rules are the experiment's strict ISP.
      networking.nftables.tables = {
        firewall = {
          family = "inet";
          content = ''
            chain input {
              type filter hook input priority filter; policy accept;
            }
            chain forward {
              type filter hook forward priority 0; policy accept;
            }
            chain output {
              type filter hook output priority 0; policy accept;
            }
          '';
        };
      };

      system.stateVersion = "26.05";
    };
  };
}
