{ home-manager, ... }:

[
  ../../common/amdgpu.nix
  ../../common/desktop.nix
  ../../common/nfs.nix
  ../../common/nosleep.nix
  ../../common/podman.nix
  ../../common/sunshine.nix
  ../../common/wine.nix

  ((import ../../common/folding-at-home.nix) "amd")

  ./ai
  # ACME (Route 53 DNS-01) + nginx TLS vhost for *.ai.chrisdell.info
  ./tls.nix
  ./litellm.nix
  ./open-webui.nix
  ./hardware-configuration.nix
  ./netboot.nix

  # One-time root partition resize (completed 2026-08-14: / 181G->250G,
  # /home 750G->681G). Left in the tree, commented out, for reference and
  # possible reuse - see docs/resize-once.md and resize-once.nix.
  # ./resize-once.nix

  ({ lib, pkgs, ... }: {

    # 74:56:3c:6f:aa:16

    environment.systemPackages = with pkgs; [
      opencode
      nodejs
    ];

    system.autoRollback.enable = true;

    # Build aarch64-linux (Raspberry Pi 5 netboot, pi5/ flake) on the
    # MacBookAir instead of cross-building: `nix build path:pi5#...` on this
    # host evaluates here and dispatches aarch64-linux drv to the MacBook,
    # copying results back into this store (which is the NFS-exported
    # /exports/nix-store the Pi boots from). The daemon (root) SSHes to the
    # MacBook as cjdell; the key below is authorized there, and cjdell is in
    # trusted-users in the MacBook's /home/cjdell/nixos-config/configuration.nix.
    nix = {
      distributedBuilds = true;
      buildMachines = [
        {
          hostName = "cjdell@192.168.49.191";
          systems = [ "aarch64-linux" ];
          maxJobs = 4;
          sshKey = "/root/.ssh/id_ed25519";
          # The linux-rpi kernel drv requires the big-parallel system feature;
          # without advertising it nix keeps that drv local and fails with a
          # platform mismatch. The MacBook's nix.conf has big-parallel.
          supportedFeatures = [ "big-parallel" ];
        }
      ];
    };

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
