{ home-manager, ... }:

[
  ../../common/desktop.nix
  ../../common/nfs.nix
  ../../common/nosleep.nix
  ../../common/podman.nix
  ../../common/sunshine.nix
  ../../common/wine.nix

  ((import ../../common/folding-at-home.nix) "amd")

  ./ai.nix
  ./hardware-configuration.nix
  ./netboot.nix

  ({ lib, pkgs, ... }: {

    # 74:56:3c:6f:aa:16

    environment.systemPackages = with pkgs; [
      opencode
      nodejs
    ];

    system.autoRollback.enable = true;

    # Let the alderlake-thinkpad use this machine as a remote Nix build machine
    # (matches the sshKey configured in hosts/alderlake-thinkpad/default.nix).
    users.users.root.openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICx2X9y6tglYE8dnTPW1j28iSmv8wftzaVhpUulB5fez root@alderlake-thinkpad (nix builder)"
    ];

    boot.kernel.sysctl = {
      # enable IPv4 and IPv6 forwarding on all interfaces
      "net.ipv4.conf.all.forwarding" = true;
      "net.ipv6.conf.all.forwarding" = true;

      "net.ipv4.conf.all.arp_filter" = 1;
      "net.ipv4.conf.default.arp_filter" = 1;
    };

    networking = {
      useDHCP = false;
      firewall.enable = false;
      networkmanager.enable = lib.mkForce false;
      nftables.enable = true;
    };

    systemd.network = {
      enable = true;
      wait-online.enable = false;

      links = {
        "10-lan" = {
          matchConfig = {
            MACAddress = "74:56:3c:6f:aa:16";
          };
          linkConfig = {
            Name = "lan";
          };
        };
      };

      netdevs = {
        # Brigde needed for QEMU quests
        "10-brlan" = {
          netdevConfig = {
            Kind = "bridge";
            Name = "brlan";
            MACAddress = "74:56:3c:6f:aa:17";
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
          bridge = [ "brlan" ];
        };

        "11-brlan" = {
          matchConfig.Name = "brlan";
          networkConfig = {
            DHCP = true;
            IPv6AcceptRA = true;
          };
        };
      };
    };
  })
]
