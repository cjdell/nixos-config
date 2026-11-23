let
  net = import ./constants.nix;
  constants = import ../constants.nix;
in
{
  systemd.network = {
    enable = true;
    wait-online.enable = false;

    links = {
      "100-lan" = {
        # Left side port
        matchConfig = {
          MACAddress = "68:1d:ef:36:e9:94";
        };
        linkConfig = {
          Name = "rawlan";
        };
      };

      "200-wan-fttp" = {
        # Right side port
        matchConfig = {
          MACAddress = "68:1d:ef:36:e9:95";
        };
        linkConfig = {
          Name = "wan-fttp";
        };
      };
    };

    netdevs = {
      # Bridge needed for QEMU quests
      "99-lan" = {
        netdevConfig = {
          Kind = "bridge";
          Name = net.LAN_INTERFACE;
          MACAddress = "68:1d:ef:36:e9:99";
        };
      };

      "110-vlan10" = {
        netdevConfig = {
          Kind = "vlan";
          Name = net.VLAN10_INTERFACE;
        };
        vlanConfig.Id = 10;
      };

      # The simulated strict ISP link for the friend-router microVM
      # (services/friend-tunnel.nix). Its uplink tap rs-friend-up is enslaved
      # below; deliberately NOT named vm-*, which the lan bridge would eat.
      "120-strict" = {
        netdevConfig = {
          Kind = "bridge";
          Name = net.STRICT_INTERFACE;
        };
      };
    };

    networks = {
      "99-lan-bridge" = {
        matchConfig.Name = [
          "rawlan"
          "vm-*"
        ];
        linkConfig.RequiredForOnline = "yes";
        networkConfig = {
          DHCP = false;
        };
        bridge = [ net.LAN_INTERFACE ];
      };

      "100-lan" = {
        matchConfig.Name = net.LAN_INTERFACE;
        linkConfig.RequiredForOnline = "yes";
        networkConfig = {
          DHCP = false;
          # have networkd send IPv6 router advertisements
          IPv6SendRA = true;
        };
        ipv6SendRAConfig = {
          # RAs should include the router's IP for DNS
          EmitDNS = true;
          DNS = net.LAN_IPV6_ADDRESS;
        };
        vlan = [
          net.VLAN10_INTERFACE
        ];
        address = [
          "${net.LAN_IPV4}/24"
          "${net.LAN_IPV6_ADDRESS}/64"
        ];
        dns = [ net.LAN_IPV4 ];
        domains = [ "grafton.lan" ];
        # See the `mark-hackspace-replies` chain in networking/firewall.nix:
        # reply-direction packets to the hackspace's public /48 are marked
        # 0x202a, and this rule sends them to table 100 — whose only route is a
        # WAN default declared on pppoe-zen in pppoe.nix — instead of to the
        # VM route in main. Priority 100 beats the local/main defaults.
        routingPolicyRules = [
          {
            # NixOS calls it FirewallMark; the module emits systemd's
            # FwMark=. 8234 = 0x202a, the value mark-hackspace-replies
            # stamps (networking/firewall.nix).
            FirewallMark = 8234;
            Table = 100;
            Priority = 100;
            Family = "ipv6";
          }
        ];
        routes = [
          {
            # Route into the leighhack tailnet via the grafton-hackspace-client
            # VM (docs/leighhack-tailscale.md). networkd must OWN this: it used
            # to be added once at boot by grafton-hackspace-client-routes.service,
            # and on 2026-11-01 a switch that restarted systemd-networkd had it
            # recreate the lan bridge — the kernel then flushed the runtime route
            # with it, black-holing 10.3.0.0/16 via the WAN default route for
            # 17 h while the oneshot sat "active (exited)" forever. A declared
            # route is re-installed every time networkd configures lan.
            Destination = net.HACKSPACE_SUBNET;
            Gateway = constants.GRAFTON_HACKSPACE_CLIENT_IP;
            # The VM's tap may come up after lan (boot, or a VM restart);
            # installing the route must not depend on the gateway answering.
            GatewayOnLink = true;
          }
          # The public hackspace /48 (2001:8b0:1d14::/48) is deliberately
          # NOT routed through the VM any more (removed 2026-11-23 — it was
          # added 2026-11-19; the whole story is in docs/leighhack-tailscale.md).
          # It is public IPv6 owned by the hackspace, their nginx on
          # 2001:8b0:1d14:225::1 is reachable from the internet, and they now
          # keep a standing firewall allow for the Grafton IPv6 ranges, so
          # every house v6 request for it should just leave over Zen.
          # Measured that same day, house client -> internet path: 302 in
          # ~0.13 s steady, frigate.int vhost 200 in ~0.07 s; via the tunnel:
          # the same request took ~1 s of TCP retransmissions while the
          # tailnet path was settling, and during a gw<->VM flap LAN clients
          # saw SYN-never-answered ([UNREPLIED] storms in conntrack) for
          # minutes while the V4 tunnel stayed healthy — and browsers refuse
          # Happy-Eyeballs fallback on a TCP session that CONNECTS but whose
          # data stalls, which is the "hangs forever unless I force IPv4"
          # symptom. The tunnel detour bought nothing except that failure
          # mode; the 2026-11-19 rationale (their hand-written WAN ACL row
          # breaks) is superseded by the standing allow policy.
          # NOTE two things this leaves behind:
          #  * grafton-tailnet MEMBERS reaching the /48 in v6 over this box
          #    relied on this route + the hackspace-v6-nat masquerade
          #    (services/tailscale.nix, networking/firewall.nix). Their v4
          #    (.int via 10.3.0.0/16, kept) is unaffected; if member v6 ever
          #    matters again, do not restore this main-table route — re-add
          #    it scoped to iif tailscale0 via an nft meta mark + a policy
          #    rule, so house traffic stays on the clean internet path.
          #  * the mark-hackspace-replies chain (firewall.nix) and table 100
          #    (pppoe.nix) stay: their gateway still SOURCES monitoring
          #    traffic at us from 225::1 over the WAN, and those sessions
          #    must keep their replies on the same leg.
          {
            # The tailnet-only ULA counterpart, added 2026-11-19, STILL
            # routed via the VM: fd99:dead:beef::/48 is not publicly
            # routable — it is the sole v6 answer for some *.int hosts —
            # so those really do need the tailnet. The gateway is the VM's
            # link-local: derived by EUI-64 from the tap MAC
            # 02:00:00:00:00:15 that
            # virtual-machines/grafton-hackspace-client.nix pins, so it is
            # as stable as that MAC (change one, change the other). It must
            # carry NO %scope suffix — [Route] Gateway= is inet_pton(3)
            # format and systemd-networkd (v262) rejects "fe80::…%lan"
            # outright; the link-local next-hop is implicitly bound to the
            # lan link this .network file configures. (Corrections from
            # 2026-11-23: the claim here and in services/hackspace-tunnel.nix
            # that forwarded v6 arrives masqueraded as the VM's fd7a tailnet
            # address was WRONG even before the /48 change — the VM's
            # masquerade rule sits at "counter packets 0" — forwarded house
            # traffic crossed gw with the LAN client's own 2a02:… source,
            # which is what their access logs saw, and what their allow
            # policy now admits.)
            Destination = "${net.HACKSPACE_ULA_SUBNET}";
            Gateway = "fe80::ff:fe00:15";
            GatewayOnLink = true;
          }
        ];
      };

      # Experimental VLAN
      "110-vlan10" = {
        matchConfig.Name = net.VLAN10_INTERFACE;
        linkConfig.RequiredForOnline = "carrier";
        networkConfig = {
          DHCP = false;
          # have networkd send IPv6 router advertisements
          IPv6SendRA = true;
          DHCPPrefixDelegation = "yes";
        };
        dhcpPrefixDelegationConfig = {
          SubnetId = "0x10";
        };
        address = [
          "${net.VLAN10_IPV4}/24"
        ];
      };

      # friend-router VM uplink -> br-strict (strict-ISP simulation).
      # The microvm host module creates rs-friend-up at VM start; networkd
      # enslaves it on the ensuing link event.
      "115-strict-up" = {
        matchConfig.Name = "rs-friend-up";
        networkConfig = {
          DHCP = false;
        };
        bridge = [ net.STRICT_INTERFACE ];
      };

      "120-strict" = {
        matchConfig.Name = net.STRICT_INTERFACE;
        linkConfig.RequiredForOnline = "no";
        networkConfig = {
          DHCP = false;
          # v4-only "ISP": no RA, no SLAAC — the friend gets CGNAT like the
          # real strict upstream gives him, and v6 only ever via the tunnel.
          IPv6AcceptRA = false;
        };
        address = [
          "${net.STRICT_IPV4}/24"
        ];
      };

      "200-wan-fttp" = {
        # networkd should ignore the NIC connected to the fibre modem
        matchConfig.Name = "wan-fttp";
        linkConfig = {
          Unmanaged = "yes";
          RequiredForOnline = "no";
        };
      };
    };
  };
}
