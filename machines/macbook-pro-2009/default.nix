{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../pctv-linux/live-module.nix
  ];

  networking.hostName = "macbook-pro-2009-nixos"; # Define your hostname.

  # Remote Nix builds: zen3-nixos via common/build-client.nix (imported
  # through common/system.nix); root key authorized in
  # hosts/zen3-nixos/default.nix.  This box is a 2-core Core 2 Duo T9800 with
  # 7 GiB RAM, and building the pctv320cx driver used to mean building
  # nixpkgs' whole kernel tree + Rust bindings here - hours locally, minutes
  # on zen3, cached there for further iterations.  max-jobs = 1 in the client
  # module keeps local builds as a fallback when zen3 is down (raise it with
  # `nixos-rebuild ... --max-jobs N` if zen3 stays down).
  # Pinnacle PCTV 320cx (2304:022e) in the ExpressCard slot.
  #
  # The card's analog side used to be Windows-only, and was captured by
  # passing the device through to a Win7 VM (see docs/pctv-320cx.md). That VM
  # is gone.  It was then driven by an out-of-tree pctv320cx V4L2 kernel module,
  # and is now driven entirely from userspace (libusb):
  #
  #   hardware.pctv320cxLive.enable = true;   -> pctv_probe (libusb bring-up +
  #                                              BT.656 stream) + pctv-monitor
  #                                              (SDL2 GUI) + the kernel-first
  #                                              bridge handoff (TRUTH.md §2.1).
  #
  # No kernel module is built any more.  The old `hardware.pctv320cx` V4L2
  # driver (pctv-linux/nixos-module.nix) still exists for reference but is no
  # longer enabled here.
  hardware.pctv320cxLive.enable = true;
  # The bridge ROM can only be booted from cold by the in-tree
  # dvb_usb_dib0700, so that module now loads on purpose (boot.kernelModules)
  # and is unbound by pctv-bridge-handoff once the bridge is warm.
  # See pctv-linux/TRUTH.md §2.1.

  # --- watching / recording the analog inputs -------------------------------
  #
  # The card is NOT a V4L2 device any more.  With the pctv320cx module retired
  # there is no /dev/video node for it (the only ones on this box, /dev/video0
  # and /dev/video1, are the built-in iSight on uvcvideo), so nothing that
  # opens a capture device - OBS, qv4l2, mpv's av://v4l2:, ffmpeg -f v4l2 -
  # can see the composite/S-Video inputs.  The way in is the userspace stack:
  #
  #   pctv-monitor                 SDL2 live view + `c` MPEG-2 capture (720x576
  #                                interlaced mpeg2video + MP2), `1`/`Tab` switch
  #                                inputs, `a` audio input, `A` AGC, `o` monitor
  #   pctv_probe stream <input>    raw mode-2 BT.656 on stdout (diagnostics on
  #                                stderr) - what pctv-monitor consumes and
  #                                deframes to UYVY; decode-bt656.py parses it
  #
  # pctv-linux/pctv-view.sh is from the V4L2 era and only works if the module is
  # re-enabled (pctv-linux/README.md "The driver").
  #
  # mpv / obs-studio / v4l-utils stay installed for the iSight and general use:
  #   mpv av://v4l2:/dev/video0    zero-setup webcam preview
  #   qv4l2                        capture panel + controls (qvidcap is broken
  #                                here: "OpenGL Error ... InitializeGL Part 2")
  #   obs-studio                   needs OpenGL 3.3 core: the 9400M IGP (NVAC,
  #                                renderD128) reports exactly that, the 9600M GT
  #                                is nv50 (2.1) - keep OBS on card0.
  #
  # These packages are all substitutes, but mpv/obs-studio end in a wrapper
  # derivation (buildEnv) that Nix insists on building *locally*, and this
  # host runs with nix.settings.max-jobs = 0 - so a plain `just rebuild` dies
  # with "local builds are disabled".  Pass --max-jobs 1: it only re-enables
  # the tiny local wrappers, the real work still goes to zen3 (its parallelism
  # comes from nix.buildMachines.maxJobs, not from max-jobs).
  environment.systemPackages = with pkgs; [
    mpv
    obs-studio
    v4l-utils
  ];
}
