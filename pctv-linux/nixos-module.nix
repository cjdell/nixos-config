# NixOS module for the out-of-tree Pinnacle PCTV 320cx analog capture driver.
#
#   imports = [ ./pctv-linux/nixos-module.nix ];
#   hardware.pctv320cx.enable = true;
#
# RETIRED 2026-10-08 and imported by nothing: the card is driven from
# userspace now (`live-module.nix` / `hardware.pctv320cxLive`, enabled in
# machines/macbook-pro-2009/default.nix).  Kept as the documented last resort
# (pctv-linux/COLD-BOOT-NOTES.md §5.5).
#
# ⚠️ Mutually exclusive with hardware.pctv320cxLive: the blacklist below is
# exactly what the userspace path must NOT have — TRUTH.md §2.1 says the
# in-tree dvb_usb_dib0700 has to be the first firmware downloader after a cold
# plug, so live-module.nix loads it deliberately and unbinds it again once
# /dev/dvb/adapter0 shows up.  Enabling both leaves the card neither booted nor
# streamable.
#
# The driver core is Rust, so the kernel it is built against must have
# CONFIG_RUST=y (nixpkgs' regular kernel configs do).  Both firmware blobs the
# driver asks for - dvb-usb-dib0700-1.20.fw (the DiB0700 bridge's
# microcontroller) and v4l-cx25840.fw (the CX25843 standard-init program) -
# ship in linux-firmware, which enableRedistributableFirmware pulls in.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.hardware.pctv320cx;
  kp = cfg.kernelPackages;
in
{
  options.hardware.pctv320cx = {
    enable = lib.mkEnableOption ''
      the Pinnacle PCTV 320cx analog capture driver (composite / S-Video)
    '';

    kernelPackages = lib.mkOption {
      type = lib.types.raw;
      default = config.boot.kernelPackages;
      defaultText = lib.literalExpression "config.boot.kernelPackages";
      description = ''
        kernelPackages set to build the module against.  The kernel must have
        CONFIG_RUST=y.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    hardware.enableRedistributableFirmware = true;

    boot.extraModulePackages = [
      (pkgs.callPackage ./driver/package.nix {
        stdenv = kp.stdenv;
        kernel = kp.kernel;
      })
    ];

    boot.kernelModules = [ "pctv320cx" ];

    # The card enumerates as a DiB0700 DVB-T bridge; if the in-tree dvb-usb
    # driver is loaded it claims the USB interface first and the analog driver
    # never sees it.  Blacklist it (nothing DVB works on this card anyway
    # until someone writes the demod side).
    boot.blacklistedKernelModules = [
      "dvb_usb_dib0700"
      "dvb_usb"
    ];
  };
}
