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

  # --- watching / recording the analog inputs -------------------------------
  #
  # What the driver exposes (verified with v4l2-ctl --all on this host):
  #   inputs   0 Composite 1, 1 Composite 2, 2 Composite 3, 3 S-Video
  #   stds     PAL-B / NTSC-M, format YUYV 720x576 (or 720x480) interlaced,
  #            25 fps, controls brightness/contrast/saturation/hue
  #
  # obs-studio  - the one app here that covers the whole wish list: live
  #               preview, a "Video Capture Device" source with its own
  #               device/input/resolution/fps/format picker, and
  #               Settings -> Output -> Recording with an encoder choice
  #               (x264, x265, SVT-AV1, VP9 - whatever nixpkgs' ffmpeg has)
  #               into mkv/mp4/mov, plus per-source deinterlace + filters.
  #               Needs OpenGL 3.3 core: the 9400M IGP (NVAC, renderD128)
  #               reports exactly "3.3 (Core Profile)", the 9600M GT is nv50
  #               (2.1) - so keep OBS on card0, which is what kwin uses.
  #   v4l-utils - qv4l2: live view (Capture tab) + the Input tab for the four
  #               inputs and PAL/NTSC + the picture controls, which the driver
  #               writes straight into the CX25843.  v4l2-ctl for scripting.
  #               NB qvidcap is broken on this box (it exits straight away
  #               with "OpenGL Error ... InitializeGL Part 2") - use qv4l2.
  #   mpv       - zero-setup live view:  mpv av://v4l2:/dev/video0
  #               (--profile=low-latency --untimed makes it pace the frames)
  #
  # Input switching + live view in one go: pctv-linux/pctv-view.sh
  # GUI-free recording in any codec ffmpeg speaks:
  #   ffmpeg -f v4l2 -input_format yuyv422 -video_size 720x576 -framerate 25 \
  #          -i /dev/video0 -c:v libx264 -preset ultrafast -crf 23 out.mkv
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
