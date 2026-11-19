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
          {
            # The IPv6 counterparts, added 2026-11-19: every
            # *.int.leighhack.org name answers with the two hackspace AAAAs
            # (AAISP + ULA), and without these routes each one left the house
            # over Zen and arrived at the hackspace door as a WAN client,
            # admitted only by a hand-written ACL row pinned to a prefix the
            # hackspace has to keep chasing — when that row broke on
            # 2026-11-19, 794 requests got 403 while every reachability layer
            # stayed green (docs/leighhack-tailscale.md; note it blamed a Zen
            # re-delegation — it had NOT happened, which is exactly why the
            # tailnet path with its own stable source is the fix).
            # Both /48s are advertised by gw-1 and live in the VM's tailscale
            # routing table (verified: `ip -6 route show table all` ->
            # table 52; the unconditional `from all lookup 52` rule serves
            # forwarded traffic too).
            #
            # The gateway is the VM's link-local: derived by EUI-64 from the
            # tap MAC 02:00:00:00:00:15 that
            # virtual-machines/grafton-hackspace-client.nix pins, so it is as
            # stable as that MAC (change one, change the other). It must carry
            # NO %scope suffix — [Route] Gateway= is inet_pton(3)-format and
            # systemd-networkd (v262) rejects "fe80::…%lan" outright; the
            # link-local next-hop is implicitly bound to the lan link this
            # .network file configures.
            # The v6 source is the VM's tailnet address by the time it
            # reaches the hackspace — masqueraded in that file, NOT here;
            # networking/firewall.nix says why the router cannot do it.
            Destination = "${net.HACKSPACE_IPV6_SUBNET}";
            Gateway = "fe80::ff:fe00:15";
            GatewayOnLink = true;
          }
          {
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
