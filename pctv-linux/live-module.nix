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
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.hardware.pctv320cxLive;
  pctvLive = pkgs.callPackage ./package.nix { noSudo = cfg.noSudo; };

  # The raw-master share.  A 2 h tape records as ~150 GB of UYVY + 1.4 GB of
  # PCM, which no laptop SSD wants, so the master goes straight to GEN8-NAS's
  # 19 TB pool over the wired link.  Measured 2026-11-02: 21 MB/s of paced,
  # fsync'd writes to this export cost 399 ms mean and 681 ms worst over 180
  # chunks - 2.6x the capture rate, with the worst stall far inside the
  # monitor's 24 s frame queue - and zen3-nixos (32 threads, same ffmpeg) does
  # the MPEG-2 pass off the same mount later.
  #
  # The subdirectory is deliberately NOT created in the image: `pctv-masters`
  # only exists once the share is mounted, so a capture started with the NAS
  # down fails at cap_start with "not writable" instead of quietly recording a
  # tape into an empty mountpoint on the laptop disk.
  masterDir = "pctv-masters";
  masterEnv = pkgs.writeShellScriptBin "pctv-capture-nas" ''
    export PCTV_MASTER=uyvy
    export PCTV_OUT_DIR=${cfg.rawMasterMount}/${masterDir}
    if ! findmnt -T "''${PCTV_OUT_DIR}" -t nfs4 >/dev/null 2>&1; then
      echo "${cfg.rawMasterMount} is not an NFS mount - not starting a capture." >&2
      echo "A raw master is 21 MB/s; writing it to a directory that is only "
           "locally a mount point would fill this disk and look like success." >&2
      echo "Check the server, then: findmnt ${cfg.rawMasterMount}" >&2
      sleep 20
      exit 1
    fi
    exec pctv-monitor "$@"
  '';

  desktopItem = pkgs.makeDesktopItem {
    name = "pctv-monitor";
    desktopName = "PCTV 320cx Live";
    exec = "pctv-monitor";
    comment = "Live view of the Pinnacle PCTV 320cx composite / S-Video inputs";
    categories = [
      "AudioVideo"
      "Video"
    ];
    terminal = false;
  };

  desktopRaw = pkgs.makeDesktopItem {
    name = "pctv-monitor-raw-nas";
    desktopName = "PCTV Capture (raw master to NAS)";
    exec = "${masterEnv}/bin/pctv-capture-nas";
    comment = "Lossless UYVY + PCM master straight to the NAS share; transcode on zen3";
    categories = [
      "AudioVideo"
      "Video"
    ];
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

    rawMasterShare = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "192.168.49.23:/sas-24tb/ds-public";
      description = ''
        NFS export to mount for raw masters, or null for no mount.  Set when the
        capture station records lossless UYVY + PCM: 150 GB per 2 h tape belongs
        on a NAS pool, not on the laptop SSD.
      '';
    };

    rawMasterMount = lib.mkOption {
      type = lib.types.str;
      default = "/ds-public";
      description = ''
        Mount point the raw masters go under (they land in `pctv-masters` inside
        it). Defaults to where `common/nfs.nix` mounts GEN8's ds-public, so a
        capture station that imports it needs only `rawMasterMount` set - no
        second mount of an export the machine already has.
      '';
    };

    audioProfile = lib.mkOption {
      type = lib.types.str;
      default = "output:analog-stereo+input:analog-stereo";
      example = "output:analog-stereo";
      description = ''
        WirePlumber profile to prefer on every ALSA sound card, so the audio
        path `pctv-monitor` needs exists without anyone touching the desktop
        audio menu.  The monitor captures and plays back through the sound
        server (ALSA `default` is PipeWire's plugin), which needs a profile
        with **both** a sink and a source: with the profile off the sink is a
        Dummy Output (no monitoring, no desktop sound), and with an output-only
        profile there is no source (no capture).  Set to `""` to leave
        WirePlumber's own choice alone.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # The raw-master share, mounted at boot.  `hard` rather than `soft` on
    # purpose: a soft mount answers EIO to ffmpeg once its retries run out, and
    # that is how a tape dies halfway through.  A hard mount waits instead, and
    # the monitor's frame queue (600 frames = 24 s, and it now stops the capture
    # out loud rather than dropping pictures) is what rides out the wait.
    fileSystems.${cfg.rawMasterMount} = lib.mkIf (cfg.rawMasterShare != null) {
      device = cfg.rawMasterShare;
      fsType = "nfs4";
      options = [
        "vers=4.2"
        "proto=tcp"
        "rsize=1048576"
        "wsize=1048576"
        "hard"
        "timeo=100"
        "retrans=5"
        "noatime"
        "nodiratime"
        "_netdev"
        "x-systemd.mount-timeout=60"
      ];
    };
    # The kernel downloads the bridge firmware through the normal firmware
    # path; the userspace package carries its own uncompressed copies.
    hardware.enableRedistributableFirmware = true;

    # The monitor's only cushion between a 27 MB/s BT.656 stream and a 2-core
    # box that is simultaneously running ffmpeg, the SDL display, kwin and the
    # USB workers is a pipe. The unprivileged default cap (fs.pipe-max-size =
    # 1 MiB) is 39 ms of slack, and one scheduling hiccup past that made the
    # probe's non-blocking write fail and discard a whole 32 KiB URB = 19
    # BT.656 lines; the parser then spliced the field across the hole, which is
    # exactly the "one interlaced field is misaligned" glitch seen in the live
    # view and in the recorded .mpg. Raise the cap so pctv-monitor can ask for
    # 32 MiB (1.2 s of slack) instead of 1 MiB.
    #
    # Since 2026-11-01 the probe also queues 64 MiB (2.4 s) in front of this pipe
    # and never discards on EAGAIN (docs/pctv-analog-capture.md §11), so a
    # refused F_SETPIPE_SZ is now a latency regression rather than lost tape -
    # which is why the stream queue is sized from the same arithmetic and why
    # both are declared here instead of being left to chance.
    #
    # Since 2026-11-02 the *card's* side has one too: the probe keeps 128 URBs
    # (4 MiB = 155 ms) posted on the endpoint instead of 24 (28 ms), which is the
    # only cushion that stops the device dropping whole fields when the host is
    # late. That is what `usbfs_memory_mb` below and PCTV_URBS size; "we lost a
    # field every few seconds" and "a pipe overflowed" are different failures and
    # now have different counters (§14).
    # The kernel's usbfs buffer accounting is a *streaming* limit, not a driver
    # detail: usbfs_memory_mb (16 MiB by default) is the total pinned memory it
    # will hold for every URB of every libusb user on the box, and a submit that
    # does not fit is refused - which does not fail, it just makes the pipe
    # narrower and the card's FIFO overflows sooner.  Since 2026-11-02 the probe
    # keeps 128 URBs x 32 KiB (4 MiB) posted, i.e. 155 ms of device-side cushion
    # instead of the 28 ms that 24 URBs bought, so the budget has to be raised.
    # The probe raises it itself at stream start (it is root, and it is the only
    # thing that knows what it is about to ask for); this makes it true earlier
    # and for everything else too.
    boot.kernelParams = [ "usbcore.usbfs_memory_mb=64" ];

    boot.kernel.sysctl."fs.pipe-max-size" = lib.mkDefault "67108864";

    # ...and the per-user half of the same arithmetic.  `F_SETPIPE_SZ` charges
    # the buffer to the *user* that created the pipe, against
    # `fs.pipe-user-pages-soft` (default 16384 pages = 64 MiB, enforced for
    # unprivileged users only).  pctv-monitor alone asks for 32 MiB (stream) +
    # 8 MiB (encoder video) + 1 MiB (encoder audio) = 41 MiB, and every other
    # pipe in the Plasma session - Qt's QProcess pairs, Wayland event fds,
    # konsole, PipeWire - draws on the same 64 MiB.  When the budget runs out
    # the request is refused with EPERM and pipe_slack() quietly halves its way
    # down to 16 MiB (0.6 s) with nothing but one stderr line to say so.  Give
    # it 256 MiB so the cushion the code asks for is the cushion it gets.
    boot.kernel.sysctl."fs.pipe-user-pages-soft" = lib.mkDefault "65536";

    # --- never drop a frame: RT scheduling for the capture path --------------
    #
    # Buffers only buy time; the guarantee comes from not being preempted.  Both
    # binaries now ask for SCHED_FIFO at startup (`pctv-linux/pctv-rt.h` for the
    # reasoning and the per-stage priorities: probe FIFO 10, monitor FIFO 8,
    # ffmpeg deliberately demoted back to SCHED_OTHER by the monitor because an
    # RT encoder on a 2-core box starves the thread that feeds it).
    #
    # The probe gets there by itself - it runs as root through `sudo -n`.
    # pctv-monitor runs as the user, and sched_setscheduler(2) to SCHED_FIFO
    # wants CAP_SYS_NICE or RLIMIT_RTPRIO > 0, so the login limit goes here.
    # 20 rather than 8 leaves room to raise PCTV_RT_PRIO without another PAM
    # change.  Needs a fresh login (or reboot) to apply: the value is read by
    # pam_limits when the session is opened, not by `nixos-rebuild switch`.
    # To check: `ssh cjdell@localhost 'ulimit -r'` must print 20, and
    #   ps -c -o pid,cls,rtprio,ni,comm -C pctv-monitor,pctv_probe,ffmpeg
    # must show `FF` (not `TS`) for the first two and `TS` for ffmpeg.
    # If RT is ever refused the programs say so on stderr and run anyway, and
    # PCTV_RT_PRIO=0 switches the whole thing off for an A/B run.
    security.pam.loginLimits = [
      {
        domain = "@wheel";
        type = "-";
        item = "rtprio";
        value = "20";
      }
      # pctv-monitor mlock()s the capture rings (24 x 829 KB of frame queue +
      # 1 MiB of audio, prefaulted at the first `c') so that a first-touch page
      # fault cannot land in the middle of a field.  The default RLIMIT_MEMLOCK
      # for an unprivileged user is 64 KiB, so without this the mlock is refused
      # and the protection is only the prefault.  Refused is not fatal - it says
      # so on stderr and carries on.
      {
        domain = "@wheel";
        type = "-";
        item = "memlock";
        value = "1048576"; # KiB = 1 GiB, comfortably over the ~30 MB asked for
      }
    ];

    # Safety net for that: kernel 7.2 with CONFIG_RT_GROUP_SCHED=n ships with RT
    # throttling *off* (`sched_rt_runtime_us == sched_rt_period_us`, verified on
    # this box), so a runaway RT thread used to mean a machine you cannot even
    # ssh into - and an RT loop is exactly the failure mode an SDL render loop
    # could reach.  Restore the upstream 95 % cap: the capture path wants ~0.7
    # of 2 cores, so it cannot bite, and the other 5 % is what keeps a live
    # session alive if one of these processes ever spins.
    boot.kernel.sysctl."kernel.sched_rt_runtime_us" = lib.mkDefault "950000";

    # `pctv-monitor` is the SDL2 live view + MPEG-2 capture GUI: it spawns
    # pctv_probe, deframes BT.656 to UYVY, shows it, and pipes it - together
    # with the selected ALSA audio input - to ffmpeg for a PAL-DVD-style .mpg.
    # The audio is metered live (pctv-linux/README.md); the card's own
    # audio-over-USB path is still undecoded, so the L/R RCAs have to land on a
    # host input (line-in on this box).
    environment.systemPackages = [
      pctvLive
      desktopItem
      desktopRaw
      # The wrapper the raw-master desktop entry runs.  It is on PATH as well,
      # because that is what `pctv-monitor --help` points at for a terminal run,
      # and because the mount check belongs in one place - not in a shell line
      # somebody retypes.
      masterEnv
      pkgs.alsa-utils
    ];

    # Make the audio path survive reboots and desktop fiddling.  WirePlumber
    # 0.5 picks a profile in this order: one a client is asking for, then the
    # one *stored* in ~/.local/state/wireplumber/default-profile (whatever the
    # desktop audio menu last chose), then the preference from
    # device.profile.priority.rules, then its own best guess.  `priorities` is a
    # JSON *string* - find-preferred-profile.lua parses it with Json.Raw.
    #
    # The stored profile outranks the preference, and on this box it had stored
    # `off` (left by a `wpctl set-profile` experiment), which is how the machine
    # ended up with a Dummy Output, no source and no desktop sound at all.  So
    # the state is not restored either: on this host the audio profile is
    # declared in NixOS, not chosen at runtime.  (Verified from a debug run:
    # `Found stored profile 'off'` beat the priority rule until
    # `device.restore-profile = false` was set.)
    services.pipewire.wireplumber.extraConfig.pctv320cx-audio = lib.mkIf (cfg.audioProfile != "") {
      "wireplumber.settings" = {
        "device.restore-profile" = false;
      };
      "device.profile.priority.rules" = [
        {
          matches = [ { "device.name" = "alsa_card.*"; } ];
          actions.update-props.priorities = builtins.toJSON [
            cfg.audioProfile
            "input:analog-stereo+output:analog-stereo"
            "output:analog-stereo"
          ];
        }
      ];
    };

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
