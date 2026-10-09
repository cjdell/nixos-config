# NixOS module for the *userspace* Pinnacle PCTV 320cx live monitor.
#
#   imports = [ ./pctv-linux/live-module.nix ];
#   hardware.pctv320cxLive.enable = true;
#
# This replaces the out-of-tree `hardware.pctv320cx` V4L2 kernel driver: it
# installs `pctv-monitor` (SDL2 GUI) + `pctv_probe` (libusb userspace driver)
# and reaches the card directly over libusb - no kernel module to build.
#
# The card's bridge ROM can only be booted from cold by the kernel's in-tree
# `dvb_usb_dib0700`; a userspace download poisons the ROM (see
# pctv-linux/TRUTH.md §2.1).  So this module loads that driver first (it does
# the firmware download), then a `pctv-bridge-handoff` unit unbinds it once the
# bridge is warm and the frontend has registered, leaving interface 0 free for
# libusb.  Set `noSudo = true` to let a normal user (group `video`) open the
# card; otherwise the GUI invokes the probe through `sudo -n`.
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

  # Load the in-tree driver (it must be the FIRST downloader after a cold
  # power-up), wait for the kernel to finish booting the bridge (the frontend
  # only registers after a *full* boot => /dev/dvb/adapter0 appears), then
  # unbind it so libusb can claim interface 0.  A cold card that only
  # half-boots never gets adapter0; the bridge is then unusable until the next
  # power-cycle anyway, so timing out is not fatal (and on a warm bridge there
  # is nothing to do).
  bridgeHandoff = pkgs.writeShellScript "pctv-bridge-handoff" ''
    set -u
    # Wait for NixOS to point the firmware loader at its firmware (the
    # cold-boot udev add event can fire before activation writes this).
    i=0
    while [ "$i" -lt 150 ]; do
      [ -s /sys/module/firmware_class/parameters/path ] && break
      sleep 0.2
      i=$((i + 1))
    done
    # Load the module only now, so the download cannot run before the
    # firmware path is set.
    modprobe dvb_usb_dib0700 || true
    i=0
    while [ "$i" -lt 100 ]; do
      [ -e /dev/dvb/adapter0 ] && break
      sleep 0.2
      i=$((i + 1))
    done
    if [ ! -e /dev/dvb/adapter0 ]; then
      echo "pctv-bridge-handoff: no /dev/dvb/adapter0 (bridge already warm, or cold boot failed)" >&2
      exit 0
    fi
    sleep 1
    for d in /sys/bus/usb/drivers/dvb_usb_dib0700/*:*; do
      [ -e "$d" ] || continue
      iface="$(basename "$d")"
      echo "pctv-bridge-handoff: releasing $iface to userspace"
      echo "$iface" > /sys/bus/usb/drivers/dvb_usb_dib0700/unbind || true
    done
  '';
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
    # The kernel downloads the bridge firmware through the normal firmware
    # path; the userspace package carries its own uncompressed copies.
    hardware.enableRedistributableFirmware = true;

    # `pctv-monitor` is the SDL2 live view + MPEG-2 capture GUI: it spawns
    # pctv_probe, deframes BT.656 to UYVY, shows it, and pipes it - together
    # with the selected ALSA audio input - to ffmpeg for a PAL-DVD-style .mpg.
    # The audio is metered live (pctv-linux/README.md); the card's own
    # audio-over-USB path is still undecoded, so the L/R RCAs have to land on a
    # host input (line-in on this box).
    environment.systemPackages = [ pctvLive desktopItem pkgs.alsa-utils ];

    # `dvb_usb_dib0700` must be the FIRST downloader after a cold power-up
    # (TRUTH.md §2.1); the handoff unit loads it once the firmware path is
    # set, then releases it to libusb.  No early `boot.kernelModules` load, so
    # the download cannot race the firmware path being configured.

    systemd.services.pctv-bridge-handoff = {
      description = "Boot the PCTV 320cx bridge via dvb_usb_dib0700, then release it to libusb";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-modules-load.service" ];
      path = [
        pkgs.coreutils
        pkgs.kmod
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = bridgeHandoff;
      };
    };

    # Allow group `video` to open the card when noSudo = true, and (re)run the
    # handoff whenever the card is inserted.
    services.udev.extraRules = ''
      SUBSYSTEM=="usb", ATTR{idVendor}=="2304", ATTR{idProduct}=="022e", GROUP="video", MODE="0660", TAG+="systemd", ENV{SYSTEMD_WANTS}+="pctv-bridge-handoff.service"
    '';
  };
}
