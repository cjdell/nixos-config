{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../pctv-linux/live-module.nix
  ];

  networking.hostName = "macbook-pro-2009-nixos"; # Define your hostname.

  # Remote Nix build machine: zen3-nixos (192.168.49.50, 16 cores).
  #
  # This box is a 2-core Core 2 Duo T9800 with 7 GiB RAM.  Building the
  # pctv320cx module (pctv-linux/, hardware.pctv320cx below) means building
  # nixpkgs' whole kernel build tree + generating the Rust bindings against it
  # - hours here, minutes on zen3, and it stays cached there so further driver
  # iterations are seconds.  Same setup as hosts/alderlake-thinkpad: ssh-ng as
  # root, key authorized in hosts/zen3-nixos/default.nix.
  nix.distributedBuilds = true;
  # Build exclusively on the builder: max-jobs = 0 disables local builds, so
  # every derivation goes to zen3 (16 parallel jobs there).  Don't pass
  # --max-jobs to nixos-rebuild - it overrides this and serializes remote
  # builds to one at a time.  If zen3 is down, override to build locally:
  # `sudo nixos-rebuild ... --max-jobs 1` (root is a trusted user).
  nix.settings.max-jobs = 0;
  nix.buildMachines = [
    {
      hostName = "192.168.49.50";
      protocol = "ssh-ng";
      sshUser = "root";
      sshKey = "/root/.ssh/id_ed25519";
      system = "x86_64-linux";
      maxJobs = 16;
      speedFactor = 4;
      supportedFeatures = [
        "nixos-test"
        "benchmark"
        "big-parallel"
      ];
    }
  ];
  # Pin the builder's SSH host key so ssh-ng connects without a prompt.
  programs.ssh.knownHosts."192.168.49.50" = {
    hostNames = [ "192.168.49.50" ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFdeRHV02KmEdG3YoH2aq1++9PqeTwGlWUsG0XKzUE27";
  };

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
