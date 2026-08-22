# Raspberry Pi 5 (aarch64) NixOS — network-bootable over the RPi 5 EEPROM's
# TFTP client, with the Nix store mounted from zen3 over NFS.
#
# Boot flow (no SD card):
#   1. EEPROM DHCPs from the router (next-server = zen3), TFTP-fetches
#      e9cf02dc/{config.txt,dtb,cmdline.txt,Image,initrd} from zen3.
#   2. The kernel boots with the small initrd, which DHCPs (networkd) and
#      mounts /nix/.ro-store from 192.168.49.50:/nix-store (NFSv4) and
#      starts systemd from the toplevel.
#
# TFTP size constraints (RPi EEPROM client, blksize forced to 512):
#   * reliable up to ~33 MB (16-bit block numbers); the 38.5 MB Image
#     transfers fine (RFC2349 wraparound + zero-length terminator handled)
#     but must complete within TFTP_FILE_TIMEOUT (30 s), so it stays raw.
#   * the 454 MB netboot ramdisk is NOT an option — hence NFS root.
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

let
  nfsServer = "192.168.49.50";
in
{
  imports = [ (modulesPath + "/profiles/base.nix") ];

  networking.hostName = "pi5";
  networking.useDHCP = lib.mkForce true;

  # We boot via the RPi EEPROM + TFTP, not an on-disk loader.
  boot.loader.grub.enable = lib.mkDefault false;
  boot.loader.generic-extlinux-compatible.enable = lib.mkForce false;

  # The Pi 5 GbE sits behind the RP1 (PCIe); the driver stack must be in the
  # initrd so the (post-boot) network comes up for NFS.
  boot.initrd = {
    availableKernelModules = [ "macb" "rp1" "pcie-brcmstb" "clk-rp1" "nfs" "nfsv4" "sunrpc" ];

    # The linux-rpi kernel does not build the tpm-crb module; the default
    # systemd initrd enables TPM2 (which needs tpm-crb) and the
    # modules-shrunk step fails with "Module tpm-crb not found". The Pi 5
    # has no TPM, so disable it.
    systemd.tpm2.enable = lib.mkDefault false;

    network = {
      enable = true;
      flushBeforeStage2 = false; # otherwise NFS doesn't work
      # Emergency access while in the initrd (debugging).
      ssh = {
        enable = true;
        authorizedKeys = [
          "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCbDJ7tQwODw2kx2f1bstOUElKnaR3hP2RbwCsf6zebZ5n/1CFUoM2Ye78D/IG/6kgDc22wD9EkzyvIwF/96fp3IgxK5ja/Q0pEhbd8xAPGIpFC7BUyePqozRusSvJXl7RamBb8lgsjySQxJxYX9MQzbQkfasWOwWE+WWqiC9nwk6WiER7EraOdEVNNF9cuNS/LVFrQZG5xdzI5gSgaxth2kQSgE3z7jIIvmlYkChEjTMXSQt9MrluhWB1nzGDHVrcqW8uu/jAqeMhRCXP39wtmL21v3WFn1jwDQlOgbR1CxnBzy+jE62TqvOJg8x6/J2WC/VXcdndHq1vKYP0s5mQn cjdell@gmail.com"
        ];
        hostKeys = [
          ./ssh_host_ed25519_key
        ];
      };
    };

    supportedFilesystems = [ "nfs" "nfsv4" ];

    systemd = {
      initrdBin = [
        pkgs.iproute2
        pkgs.iputils
        pkgs.nfs-utils # mount.nfs helper — required for the NFS root mount
      ];
      network.wait-online.extraArgs = [ "-4" ]; # wait for IPv4 so NFS can mount
    };
  };

  # Root on tmpfs, Nix store read-only over NFSv4 with a tmpfs overlay.
  fileSystems."/" = {
    fsType = "tmpfs";
    options = [ "mode=0755" ];
  };

  fileSystems."/nix/.ro-store" = {
    fsType = "nfs4";
    device = "${nfsServer}:/nix-store";
    options = [
      "ro"
      "rsize=1048576"
      "hard"
      "nocto"
      "noatime"
      "actimeo=86400"
      "_netdev"
      "noacl"
    ];
    neededForBoot = true;
  };

  fileSystems."/nix/.rw-store" = {
    fsType = "tmpfs";
    options = [ "mode=0755" ];
    neededForBoot = true;
  };

  fileSystems."/nix/store" = {
    overlay = {
      lowerdir = [ "/nix/.ro-store" ];
      upperdir = "/nix/.rw-store/store";
      workdir = "/nix/.rw-store/work";
    };
    neededForBoot = true;
  };

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
  };

  users.users.root = {
    initialPassword = "nixos";
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCbDJ7tQwODw2kx2f1bstOUElKnaR3hP2RbwCsf6zebZ5n/1CFUoM2Ye78D/IG/6kgDc22wD9EkzyvIwF/96fp3IgxK5ja/Q0pEhbd8xAPGIpFC7BUyePqozRusSvJXl7RamBb8lgsjySQxJxYX9MQzbQkfasWOwWE+WWqiC9nwk6WiER7EraOdEVNNF9cuNS/LVFrQZG5xdzI5gSgaxth2kQSgE3z7jIIvmlYkChEjTMXSQt9MrluhWB1nzGDHVrcqW8uu/jAqeMhRCXP39wtmL21v3WFn1jwDQlOgbR1CxnBzy+jE62TqvOJg8x6/J2WC/VXcdndHq1vKYP0s5mQn cjdell@gmail.com"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMBx9ohs90FxZ+YZvMUcon1UlG+9LWQSl/G8UjPTkFbU cjdell@pop-os.localdomain"
    ];
  };

  # Keep the closure (and thus the initrd + store dir) as small as possible.
  environment.systemPackages = [ ];

  # After boot, register the store paths from the NFS mount in the local
  # nix db (mirrors pxe-sys/netboot.nix).
  boot.postBootCommands = ''
    ${config.nix.package}/bin/nix-store --load-db < /nix/store/nix-path-registration
    touch /etc/NIXOS
    ${config.nix.package}/bin/nix-env -p /nix/var/nix/profiles/system --set /run/current-system
  '';

  # Build the store directory (toplevel closure + registration manifest)
  # that zen3 serves over NFS at /exports/nix-store.
  system.build.nixStore = pkgs.callPackage ./make-store-dir.nix {
    storeContents = [ config.system.build.toplevel ];
  };
}
