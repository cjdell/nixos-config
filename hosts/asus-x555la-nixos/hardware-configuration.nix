# NixOS hardware configuration for asus-x555la-nixos (ASUS X555LA).
#
# Taken from the box's live /etc/nixos/hardware-configuration.nix
# (nixos-generate-config, 2026-09-20) rather than regenerated, so the mount
# points are exactly what the running system uses. Verified against the live
# system on 2026-11-18: single SATA disk sda = KingDian S280 120GB with
# sda1 vfat 512M (label ESP) → /boot, sda2 swap 4G (label swap), sda3 ext4
# 107.3G (label `nixos`) → /; UEFI (64-bit efivarfs present, so
# systemd-boot is correct and no MBR/grub path is needed).
#
# Note the deviation from the rest of the fleet: this box mounts **by UUID**,
# because its partitions are labelled ESP/nixos/swap instead of the fleet's
# BOOT/ROOT. Relabelling a live ESP/ROOT to match would need a reboot and a
# matching initrd, for no operational gain — so it keeps its own labels.
# If the SSD is ever replaced, label the new partitions BOOT/ROOT and switch
# this file to by-label like hosts/hp-z240-xeon-1240v6-nixos.
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # rtsx_usb_sdmmc is the Realtek RTS5121 card reader (the USB2.0-CRW device)
  # and sr_mod the HL-DT-ST DVD±RW — both loaded in the initrd so a disc or an
  # SD card is there if this box ever has to be the rescue console.
  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ehci_pci"
    "ahci"
    "usb_storage"
    "usbhid"
    "sd_mod"
    "sr_mod"
    "rtsx_usb_sdmmc"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  # Console GPU is the Haswell iGPU (Intel HD 4400, 8086:0a16, i915) — the
  # only display device in the box. No driver override needed: i915 + modeset
  # is the default and VAAPI (H.264 only on Haswell, no HEVC) comes from
  # hardware.graphics.
  hardware.graphics.enable = true;

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/0121af2b-9de3-4326-9bf1-b997ff7d12b6";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/0DA6-FF56";
    fsType = "vfat";
    options = [
      "fmask=0022"
      "dmask=0022"
    ];
  };

  # The 4 GiB swap partition. Keep it: with 11 GiB RAM and no zram here, it is
  # what stops a memory-hungry job from being an OOM kill.
  swapDevices = [
    { device = "/dev/disk/by-uuid/700a7c38-6fb0-4ff4-a2c1-924ca3e30aa2"; }
  ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
