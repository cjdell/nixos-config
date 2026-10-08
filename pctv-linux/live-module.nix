# NixOS module for the *userspace* Pinnacle PCTV 320cx live monitor.
#
#   imports = [ ./pctv-linux/live-module.nix ];
#   hardware.pctv320cxLive.enable = true;
#
# This replaces the out-of-tree `hardware.pctv320cx` V4L2 kernel driver: it
# installs `pctv-monitor` (SDL2 GUI) + `pctv_probe` (libusb userspace driver)
# and reaches the card directly over libusb - no kernel module to build.
#
# It only needs to keep the in-tree `dvb_usb_dib0700` DVB-T driver off the
# device so libusb can claim interface 0.  Set `noSudo = true` to let a normal
# user (group `video`) open the card; otherwise the GUI invokes the probe
# through `sudo -n`.
{ config, lib, pkgs, ... }:

let
  cfg = config.hardware.pctv320cxLive;
  pctvLive = pkgs.callPackage ./package.nix { noSudo = cfg.noSudo; };

  desktopItem = pkgs.makeDesktopItem {
    name = "pctv-monitor";
    desktopName = "PCTV 320cx Live";
    exec = "pctv-monitor";
    comment = "Live view of the Pinnacle PCTV 320cx composite / S-Video inputs";
    categories = [ "AudioVideo" "Video" ];
    terminal = false;
  };
in
{
  options.hardware.pctv320cxLive = {
    enable = lib.mkEnableOption ''
      the userspace Pinnacle PCTV 320cx live monitor (libusb, no kernel module)
    '';

    noSudo = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Open the card as the invoking user instead of through `sudo -n`.
        Requires the udev rule this module installs and no kernel driver bound
        to the device.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # The card's firmware still ships via the normal firmware path for any
    # other consumer; the package uses its own uncompressed copies.
    hardware.enableRedistributableFirmware = true;

    environment.systemPackages = [ pctvLive desktopItem ];

    # Keep the in-tree DVB USB bridge driver from claiming interface 0.
    boot.blacklistedKernelModules = [ "dvb_usb_dib0700" "dvb_usb" ];

    # Allow group `video` to open the card when noSudo = true.
    services.udev.extraRules = ''
      SUBSYSTEM=="usb", ATTR{idVendor}=="2304", ATTR{idProduct}=="022e", GROUP="video", MODE="0660"
    '';
  };
}
