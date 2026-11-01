{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ../../pctv-linux/live-module.nix
  ];

  networking.hostName = "macbook-pro-2009-nixos"; # Define your hostname.

  # --- what this box is -------------------------------------------------------
  #
  # A Pinnacle PCTV 320cx capture station: Plasma + VLC + the userspace PCTV
  # stack, and deliberately little else.  Since 2026-11-01 it runs
  # `common/desktop-light.nix` (Plasma and VLC kept, everything else that
  # `common/desktop.nix` ships by default dropped) instead of the full desktop,
  # and turns off `common/system.nix`'s fleet-wide CLI set for the same reason.
  # Measured closure before: 19.8 GB (`nix path-info -S /run/current-system`);
  # the single biggest contributors were obs-studio's `cef-binary` (2.0 GB),
  # qemu from the libvirt/virt-manager host modules (1.0 GB, the Win7 VM is
  # gone), rustc/cargo + clang/llvm + deno from the shared package set (2.3 GB),
  # orca's speech synthesiser voices (0.7 GB), chrome/firefox/zed (1.2 GB) and
  # khelpcenter's qtwebengine (0.5 GB).
  #
  # What the desktop still has to carry for the capture job: PipeWire (the
  # monitor records via ALSA `default` and monitors through it), `ffmpeg` (the
  # MPEG-2 encoder pctv-monitor pipes into), the `pctv-linux/live-module.nix`
  # bridge handoff, and `sudo -n` for the probe (wheel is passwordless via
  # common/system.nix).
  #
  # Remote Nix builds: zen3-nixos via common/build-client.nix (imported through
  # common/system.nix); root key authorized in hosts/zen3-nixos/default.nix.
  # This box is a 2-core Core 2 Duo T9800 with 7 GiB RAM.  nix.conf still says
  # `max-jobs = 0`, so `nixos-rebuild switch --flake . --max-jobs 1` is the
  # invocation to use: the toplevel and the `system-path` buildEnv (and any
  # wrapped package) are always built *locally*, and with 0 local jobs that
  # fails with "local builds are disabled" before zen3 is even asked.  One job
  # is enough - the real work goes to zen3, whose parallelism comes from
  # nix.buildMachines.maxJobs, not from max-jobs.

  # common/system.nix's CLI/dev set (cargo, rustup, deno, nixd, flashrom,
  # stress-ng, the GPU inspectors, ...): a few GB, none of it needed here.
  # common/desktop-light.nix keeps `git` + `just` so this host can still
  # rebuild itself from ~/nixos-config.
  sharedPackages.enable = false;

  # common/system.nix's container-image update notifier: it has nothing to
  # watch here (no containers) and it is what keeps podman and nushell in this
  # box's closure. mkForce because common/system.nix assigns it plainly.
  system.updateContainers.enable = lib.mkForce false;

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

  # Only for pctv-linux/i2cprobe.c (walking the CX25843 over the bridge's i2c
  # gate by hand).  The live stack itself is pure libusb.  This used to come
  # from common/desktop.nix for ddcutil's sake.
  boot.kernelModules = [ "i2c-dev" ];

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
  # vlc (playback) / mpv / ffmpeg come from common/desktop-light.nix.  OBS and
  # v4l-utils went with common/desktop.nix: OBS could only ever see the iSight
  # now, and it cost 2.1 GB of that (cef-binary); for the iSight `mpv
  # av://v4l2:/dev/video0` is enough, and `nix shell nixpkgs#v4l-utils` is one
  # command when a capture-panel check is actually wanted.  The 9400M IGP
  # (NVAC, card0) is the one with OpenGL 3.3 core if OBS ever comes back - the
  # 9600M GT is nv50 (2.1).
}
