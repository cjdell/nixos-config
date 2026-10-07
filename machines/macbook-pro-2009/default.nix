{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../pctv-linux/nixos-module.nix
  ];

  networking.hostName = "macbook-pro-2009-nixos"; # Define your hostname.

  # Pinnacle PCTV 320cx (2304:022e) in the ExpressCard slot.
  #
  # The card's analog side used to be Windows-only, and was captured by
  # passing the device through to a Win7 VM (see docs/pctv-320cx.md). That VM
  # is gone; the card is now driven natively by the out-of-tree pctv320cx
  # driver built in this repo (pctv-linux/): composite/S-Video -> CX25843 ->
  # BT.656 over USB bulk-IN -> /dev/video0 (YUYV, 720x576/480 interlaced).
  #
  # The in-tree dvb_usb_dib0700 driver claims the same USB interface for the
  # (unused) DVB-T side and would win the probe race, so the module keeps it
  # off the device:
  #
  #   hardware.pctv320cx.enable = true;   -> boot.extraModulePackages +
  #                                          boot.kernelModules + blacklists
  #
  # Bring-up status and the reverse-engineering behind it:
  # pctv-linux/FINDINGS.md, pctv-linux/README.md.
  hardware.pctv320cx.enable = true;

  # Belt and braces: "blacklist" only affects alias resolution, so make the
  # DVB module unloadable by any path (including an explicit modprobe).
  boot.extraModprobeConfig = ''
    install dvb_usb_dib0700 ${pkgs.coreutils}/bin/false
  '';
}
