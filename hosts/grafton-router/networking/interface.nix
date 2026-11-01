let
  net = import ./constants.nix;
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
