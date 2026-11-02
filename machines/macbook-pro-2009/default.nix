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
  #
  # nouveau + apple_gmux are explicit: the IGP-only handover below wants both
  # clients registered with vga_switcheroo before anything composites.
  boot.kernelModules = [
    "i2c-dev"
    "nouveau"
    "apple_gmux"
  ];

  # --- IGP-only graphics: permanently take the 9600M GT off the bus ---------
  #
  # The 2026-11-02 lockup (crash log: `macbook-crash.txt`) was a PGRAPH hang
  # on the *discrete* GPU, with the whole graphics stack dying behind it:
  # Xwayland's render channel on 02:00.0 started rejecting compute methods
  # (`gr: DATA_ERROR 00000004 [INVALID_VALUE] ... class 8297 mthd 0204`, 65x),
  # then fences stopped completing - `ttm_bo_delayed_delete` workers and
  # `nv50_disp_atomic_commit_work` all wedged in `dma_fence_wait_timeout`,
  # `failed to idle channel 7`, a `nouveau ... : timeout` and a WARNING in
  # `g84_ectx_bind` as VLC closed its channel - and the session died with it.
  # The 9600M GT (G96) in a MacBookPro5,1 is the textbook dying GPU (Apple ran
  # a repair program for exactly this chip), and it is also the worse fit for
  # this box: nv50 stops at OpenGL 2.1 and it owns the only display output the
  # capture station does not use (the mini-DP), while the MCP79's 9400M does
  # OpenGL 3.3.
  #
  # So the LCD now runs off the 9400M (03:00.0) alone. This is the Linux
  # equivalent of macOS's "integrated only" mode on this model: the classic
  # gmux (apple-gmux 1.7.3, detected in that same log) multiplexes the panel
  # between the two GPUs and, unlike later MacBook Pros, can fully power-gate
  # the discrete chip - the in-kernel `apple-gmux` driver documents that
  # `GMUX_PORT_DISCRETE_POWER` "cut[s] power to the discrete GPU ... the
  # correct sequence to tear down and bring up the power rails for core
  # voltage, VRAM and PCIe", and vga_switcheroo drives it from
  # `/sys/kernel/debug/vgaswitcheroo/switch`. Writing `IGD` flips the panel
  # (and DDC) to the MCP79 *and*, as vga_switcheroo changes the active client,
  # suspends the dGPU's nouveau instance and runs that gmux power-down, so the
  # card leaves the bus and can never wedge PGRAPH (or get selected as the
  # boot GPU's render device) again.
  #
  # Nothing is blacklisted: vga_switcheroo needs nouveau bound to *both* GPUs
  # for the switch file to exist, and the EFI boot console lives on the dGPU.
  # The handover is just ordered before any compositor can appear - the unit
  # runs before the display manager, at a point where only fbcon is on
  # card0 and the mux switch is cheap.
  #
  # Consequences, and what to check:
  #   * external mini-DisplayPort is dead while the dGPU is off (it is wired
  #     to it; macOS integrated-only mode drops it too). The internal panel,
  #     keyboard and everything else are unaffected.
  #   * `lspci` shows 02:00.0 as powered off/vanished after boot;
  #     `cat /sys/kernel/debug/vgaswitcheroo/switch` is the state.
  #   * if gmux ever leaves the rails down across a reset (seen after force-
  #     power-cycling a hung reboot) the next boot comes up with no dGPU at
  #     all and a black panel; the unit notices the missing DIS client and
  #     falls back to `MIGD`, the mux-only command, so the console comes back
  #     on the MCP79. EFI re-initialises the rails on a true cold boot (~10 s
  #     power-button hold).
  #   * to get the dGPU back (e.g. to run the fence-hang test against it),
  #     delete this stanza's service - the rest of the config is independent.
  systemd.services.mbp51-igp-only = {
    description = "MacBookPro5,1 hybrid graphics: mux panel to 9400M, power off 9600M GT";
    wantedBy = [ "multi-user.target" ];
    before = [
      "display-manager.service"
      "sddm.service"
    ];
    serviceConfig.Type = "oneshot";
    script = ''
      set -u
      # Service scripts get systemd's minimal PATH: util-linux is not in it, and
      # nothing else in here should depend on what happens to be. grep/tr/seq are
      # replaced by bash builtins below for the same reason.
      util="${pkgs.util-linux}/bin"
      sw=/sys/kernel/debug/vgaswitcheroo/switch

      read_state() { cat "$sw" 2>/dev/null; }
      has_line() { case "$(read_state)" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

      # NixOS mounts debugfs in stage 2; keep the mount as a fallback.
      mkdir -p /sys/kernel/debug
      [ -e "$sw" ] || "$util/mount" -t debugfs debugfs /sys/kernel/debug || true

      # The switch file appears once apple-gmux has registered its handler;
      # clients show up as nouveau binds each GPU. Coldplug still races this
      # unit, so give it up to 30 s every boot before deciding anything.
      for ((i = 0; i < 60; i++)); do
        has_line 'DIS:' && has_line 'IGD:' && break
        sleep 0.5
      done
      if ! has_line 'IGD:'; then
        # No gmux/switcheroo at all, or nouveau never bound the MCP79 - do not
        # fail the boot over it; the box is a normal dual-GPU machine this time.
        echo "no vgaswitcheroo IGD client; leaving both GPUs up" >&2
        exit 0
      fi
      if ! has_line 'DIS:'; then
        # The dGPU never enumerated: gmux left its rails down across the last
        # reset (seen after force-power-cycling a hung reboot), so the panel -
        # still muxed toward the dead chip - is black, and there is no DIS
        # client to run the full stage dance with. `MIGD` is the mux-only
        # command: it just writes gmux's display/DDC switches to the IGP side,
        # which brings the console back on the MCP79. Boot stays otherwise
        # dual-GPU minus a dead dGPU; a 10 s power-button hold re-inits EFI.
        echo "dGPU absent (rails still down); mux-only switch to the panel"
        echo MIGD > "$sw" || echo "mux-only switch failed" >&2
        echo "after: $(read_state)"
        exit 0
      fi

      echo "before: $(read_state)"
      # The debugfs command is `IGD` (the enum is VGA_SWITCHEROO_IGP, but the
      # parser matches "IGD"; an unknown command is accepted silently and does
      # nothing - which an earlier revision of this script discovered the hard
      # way, followed by `OFF` dutifully powering the *inactive* IGP down).
      # One write is all it takes: vga_switcheroo stage2 flips the gmux mux to
      # the MCP79 and then tears the old active client down - nouveau suspend
      # for 02:00.0 plus apple-gmux's discrete-power sequence, which cuts its
      # core/VRAM/PCIe rails. So do NOT add an `OFF` here: it targets whatever
      # is inactive, which is only the right side when the switch worked.
      echo IGD > "$sw" || echo "mux switch write failed" >&2
      sleep 1 # let gmux finish the power teardown
      state=$(read_state) # file may already be gone if clients < 2 again
      echo "after:  $state"
      case "$state" in
        *"IGD:+"*) ;;
        *) echo "panel did not switch to the 9400M; dGPU still owns it" >&2 ;;
      esac
    '';
  };

  # Belt and braces: tell KWin explicitly which card is its compositor card.
  # After the handover there is only one card left anyway, but this keeps the
  # session pinned to the MCP79 (by PCI path, since card minors flip with
  # probe order) even if the oneshot above ever lands after sddm.
  environment.sessionVariables.KWIN_DRM_DEVICE = "/dev/dri/by-path/pci-0000:03:00.0-card";

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
