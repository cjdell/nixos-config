{
  lib,
  pkgs,
  specialArgs,
  ...
}:

let
  sys = (import ../../pxe-sys) { inherit lib pkgs specialArgs; };
  build = sys.config.system.build;
  nfsServer = "zen3-nixos.grafton.lan";
in
{
  environment = {
    etc = {
      # "tftp/ipxe.efi".source = ../../pxe-sys/ipxe-legacy.efi; # USB Keyboard is broken on older systems and requires legacy iPXE
      # "tftp/ipxe.efi".source = "${pkgs.ipxe}/snp.efi";
      "tftp/ipxe.efi".source = "${pkgs.callPackage ../../common/overrides/ipxe.nix { }}/snponly.efi";

      "tftp/undionly.kpxe".source = "${pkgs.ipxe}/undionly.kpxe";
      "tftp/autoexec.ipxe".source = "${pkgs.writeText "autoexec.ipxe" ""}"; # Stop error message
      "netboot.ipxe".source = pkgs.writeText "netboot.ipxe" ''
        #!ipxe

        console --x 1920 --y 1080 ||
        console --picture http://${nfsServer}/boot/logo.png ||

        # Show boot menu with timeout
        :start
        menu Boot Options
        item --gap --             --------------------- Boot Options ---------------------
        item --default local      Start Local (Exit)
        item local2               Start Local (Windows EFI)
        item network              Start Linux
        item --gap --             --------------------------------------------------------
        choose --timeout 10000 --default local selected || goto cancel
        goto ''${selected}

        :network
        kernel --name kernel  http://${nfsServer}/boot/bzImage
        initrd --name initrd0 http://${nfsServer}/boot/initrd
        boot kernel initrd=initrd0 init=${build.toplevel}/init ${lib.strings.concatStringsSep " " sys.config.boot.kernelParams}

        :local
        echo Exiting to next boot device...
        exit 1

        :local2
        echo Exiting to next boot device 2...
        sanboot --drive 0 --extra \\EFI\\Microsoft

        :cancel
        echo Boot cancelled, exiting to next boot device...
        exit 1
      '';
    };

    systemPackages = with pkgs; [
      ipxe
      tftp-hpa
      wol
      qemu
      OVMF
    ];
  };

  virtualisation.libvirtd = {
    enable = true;
    allowedBridges = [ "brlan" ];
  };

  systemd.services = {
    tftpd = {
      after = [ "nftables.service" ];
      description = "TFTP server";
      serviceConfig = {
        User = "root";
        Group = "root";
        Restart = "always";
        RestartSec = 5;
        Type = "exec";
        # -s (secure) chroots to /etc/tftp so relative requests (the RPi 5
        # eeprom, iPXE) resolve inside the tftp root; without it the
        # directory arg is only an allow-list prefix and relative requests
        # are rejected with "Only absolute filenames allowed".
        ExecStart = "${pkgs.tftp-hpa}/bin/in.tftpd -l -s -a 192.168.49.50:69 -P /run/tftpd.pid /etc/tftp";
        TimeoutStopSec = 20;
        PIDFile = "/run/tftpd.pid";
      };
      wantedBy = [ "multi-user.target" ];
    };
  };

  services.nginx = {
    enable = true;

    recommendedTlsSettings = true;
    recommendedOptimisation = true;
    recommendedGzipSettings = true;

    virtualHosts = {
      "zen3-nixos.grafton.lan" = {
        locations = {
          "= /boot/bzImage" = {
            alias = "${build.kernel}/bzImage";
          };

          "= /boot/initrd" = {
            alias = "${build.netbootRamdisk}/initrd";
          };

          "= /boot/netboot.ipxe" = {
            alias = "/etc/netboot.ipxe";
          };

          "= /boot/logo.png" = {
            alias = "${../../pxe-sys/leigh-logo.png}";
          };

          "/" = {
            tryFiles = "$uri $uri/ =404";
          };
        };
      };
    };
  };

  boot.kernel.sysctl = {
    # TCP buffer sizes
    "net.core.rmem_max" = 134217728;
    "net.core.wmem_max" = 134217728;
    "net.ipv4.tcp_rmem" = "4096 87380 134217728";
    "net.ipv4.tcp_wmem" = "4096 65536 134217728";
    "net.core.netdev_max_backlog" = 5000;

    # Readahead buffering
    "vm.dirty_ratio" = 40;
    "vm.dirty_background_ratio" = 10;
  };

  services.nfs.server = {
    enable = true;
    # /exports is the NFSv4 pseudo-root (fsid=0). The Pi 5's store snapshot
    # (the gc-rust-node pi5-netboot bundle's nixStore/nix-store, bind-mounted
    # at /exports/nix-store in ./pi5-netboot.nix — NOT this host's own
    # /nix/store) is exposed in the NFSv4 namespace at :/nix-store — what the
    # Pi mounts (pi5/configuration.nix in the gc-rust-node repo).
    #
    # The /exports/nix-store sub-export (nohide) is REQUIRED: the store bind
    # lives on the same filesystem as the /exports pseudo-root, so relying on
    # crossmnt alone makes the crossed entry share fsid=0 with the parent and
    # a client mounting :/nix-store gets an ambiguous file handle — nfsd
    # answers the mount with the pseudo-root's fileid, the client compares it
    # against the crossed root's and bails with "fileid changed" / "Stale
    # file handle" in the initrd (stage-2 never comes up). Verified
    # empirically on 2026-08-26: with only the fsid=0 crossmnt export the Pi
    # (and any client) cannot mount :/nix-store; with the explicit nohide
    # sub-export (own fsid) it mounts cleanly.
    #
    # Trade-off: the sub-export pins the bind mount, so a switch's restart of
    # exports-nix\x2dstore.mount can fail on a busy bind — scripts/update-pi5-node.sh
    # handles that (conditional fixup ending in a full `exportfs -ua; exportfs -a`).
    exports = ''
      /exports  192.168.49.0/24(ro,fsid=0,crossmnt,insecure,no_subtree_check,async,no_auth_nlm)
      /exports/nix-store  192.168.49.0/24(ro,nohide,insecure,no_subtree_check)
      # /exports/pxe-server-squashfs      192.168.49.0/24(ro,nohide,insecure,no_subtree_check)
      # /exports/pxe-server-nix-store     192.168.49.0/24(ro,nohide,insecure,no_subtree_check)
    '';
  };

  # fileSystems."/exports/pxe-server-squashfs" = {
  #   device = "${build.squashfsStore}";
  #   fsType = "bind";
  #   options = [ "bind" ];
  # };

  # (The Pi 5's /exports/nix-store bind mount lives in ./pi5-netboot.nix —
  # it serves the bundle's store snapshot, not this host's /nix/store.)

  # Just to pin the system so it doesn't get garbaged collected
  fileSystems."/pxe-sys-toplevel" = {
    device = "${build.toplevel}";
    fsType = "bind";
    options = [ "bind" ];
  };

  # fileSystems."/exports/pxe-server-nix-store" = {
  #   device = "${build.nixStore}/nix-store";
  #   fsType = "bind";
  #   options = [ "bind" ];
  # };

  # services.kea.dhcp4 = {
  #   enable = true;
  #   settings = {
  #     interfaces-config.interfaces = [ "br227" ];

  #     lease-database = {
  #       name = "/var/lib/kea/dhcp4.leases";
  #       persist = true;
  #       type = "memfile";
  #     };

  #     renew-timer = 900;
  #     rebind-timer = 1800;
  #     valid-lifetime = 3600;

  #     # Drop non-PXE requests by making the server non-authoritative
  #     # and only responding when a PXE class matches
  #     authoritative = false;

  #     client-classes = [
  #       {
  #         name = "XClient_iPXE";
  #         test = "substring(option[77].hex,0,4) == 'iPXE'";
  #         boot-file-name = "http://aibox.int.leighhack.org/boot/netboot.ipxe";
  #       }

  #       {
  #         name = "UEFI-64-1";
  #         test = "substring(option[60].hex,0,20) == 'PXEClient:Arch:00007'";
  #         next-server = "10.3.14.32";
  #         boot-file-name = "/etc/tftp/ipxe.efi";
  #       }

  #       {
  #         name = "UEFI-64-2";
  #         test = "substring(option[60].hex,0,20) == 'PXEClient:Arch:00008'";
  #         next-server = "10.3.14.32";
  #         boot-file-name = "/etc/tftp/ipxe.efi";
  #       }

  #       {
  #         name = "UEFI-64-3";
  #         test = "substring(option[60].hex,0,20) == 'PXEClient:Arch:00009'";
  #         next-server = "10.3.14.32";
  #         boot-file-name = "/etc/tftp/ipxe.efi";
  #       }

  #       {
  #         name = "Legacy";
  #         test = "substring(option[60].hex,0,20) == 'PXEClient:Arch:00000'";
  #         next-server = "10.3.14.32";
  #         boot-file-name = "/etc/tftp/undionly.kpxe";
  #       }

  #       # Catch-all: any client that isn't PXE gets dropped
  #       {
  #         name = "DROP";
  #         test = "not (member('XClient_iPXE') or member('UEFI-64-1') or member('UEFI-64-2') or member('UEFI-64-3') or member('Legacy'))";
  #       }
  #     ];

  #     subnet4 = [
  #       {
  #         id = 1;
  #         subnet = "10.3.14.0/24";

  #         # Only PXE classes can get an address from this pool
  #         pools = [
  #           {
  #             pool = "10.3.14.100 - 10.3.14.199";
  #           }
  #         ];

  #         option-data = [
  #           {
  #             name = "routers";
  #             data = "10.3.14.1";
  #           }
  #           {
  #             name = "domain-name-servers";
  #             data = "10.3.14.1";
  #           }
  #         ];

  #         # Keep reservations so reserved PXE clients still get their fixed IPs
  #         reservations = [
  #           ({
  #             hw-address = "2c:fd:a1:6f:cb:90";
  #             ip-address = "10.3.14.110";
  #           })
  #         ];
  #       }
  #     ];
  #   };
  # };
}
