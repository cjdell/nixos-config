{
  config,
  pkgs,
  lib,
  ...
}:

# Folding@home v8 ("Bastet") as a native systemd service — the space-heater
# deployment: fold on every CPU thread and on AMD GPUs.
#
# Why not the linuxserver.io container (common/folding-at-home.nix)? That
# image only ships Intel/NVIDIA OpenCL ICDs, so it can never see an AMD GPU;
# and nixpkgs has neither the FAH client nor a ROCm OpenCL ICD any more. The
# two pieces are therefore built from upstream binaries in common/fah-packages.nix.
#
# How the pieces fit together:
#   * fah-client dlopens libOpenCL.so.1 (ocl-icd) from LD_LIBRARY_PATH;
#     ocl-icd loads the AMD ICD from OCL_ICD_VENDORS.
#   * The GPU core (FahCore_23, a centos7 OpenMM build) ships a libstdc++
#     older than the ROCm runtime needs — the documented Navi 10+ symptom is
#     the GPU slot failing/disabling. Preloading the distro libstdc++ is the
#     declarative form of the community's "symlink the system libstdc++ over
#     the core's" fix.
#   * v8 has no slots: it uses the CPUs it is told about (`cpus`, which by
#     default reserves one core) and every GPU OpenCL enumerates.
#   * v8 keeps its state (keys, account, per-GPU settings) in a SQLite DB in
#     the data directory; the XML config file only seeds options, so the
#     client may rewrite it — hence it is installed into the state directory
#     on every start rather than referenced from the read-only store.
#   * A fresh v8 client starts PAUSED (its bundled group.json says
#     `"paused": true`; folding is a Web Control button press in the intended
#     UX). The `fah-client-unpause` oneshot sends the official `fahctl fold`
#     command once the client is listening; the un-paused state persists in
#     the DB across restarts.

let
  cfg = config.services.folding-at-home-native;
  fahPackages = import ./fah-packages.nix pkgs;

  # The provisioning script connects over loopback to the first configured
  # listen address (a wildcard bind is fine to reach that way).
  provisionAddress =
    let
      a = lib.head cfg.httpAddresses;
    in
    lib.replaceStrings [ "0.0.0.0" "[::]" ] [ "127.0.0.1" "127.0.0.1" ] a;

  # cbang config file: element name = option name.
  configXml = pkgs.writeText "fah-config.xml" (
    ''
      <config>
        <user>${lib.escapeXML cfg.userName}</user>
        <team>${toString cfg.teamNumber}</team>
        <machine-name>${lib.escapeXML cfg.machineName}</machine-name>
        <http-addresses>${lib.escapeXML (lib.concatStringsSep " " cfg.httpAddresses)}</http-addresses>
        <allow>${lib.escapeXML (lib.concatStringsSep " " cfg.allowAddresses)}</allow>
    ''
    + lib.optionalString (cfg.cpus != null) "    <cpus>${toString cfg.cpus}</cpus>\n"
    + lib.optionalString (cfg.gpuUsage != null) "    <gpu-usage>${toString cfg.gpuUsage}</gpu-usage>\n"
    + lib.optionalString (cfg.accountTokenFile != null) ''
      <account-token>@ACCOUNT_TOKEN@</account-token>
    ''
    + "  </config>\n"
  );

  installConfig = pkgs.writeShellScript "fah-install-config" (
    ''
      set -euo pipefail
      dest=/var/lib/fah-client/config.xml
    ''
    + lib.optionalString (cfg.accountTokenFile != null) ''
      sed "s|@ACCOUNT_TOKEN@|$(cat ${cfg.accountTokenFile})|" ${configXml} >"$dest"
    ''
    + lib.optionalString (cfg.accountTokenFile == null) ''
      cat ${configXml} >"$dest"
    ''
    + ''
      chown fah:fah "$dest"
      chmod 0600 "$dest"
    ''
  );
in
{
  options.services.folding-at-home-native = {
    enable = lib.mkEnableOption ''
      Folding@home v8 client as a native systemd service, folding on CPU
      threads and on AMD GPUs via a bundled ROCm 6.4.3 OpenCL runtime
    '';

    userName = lib.mkOption {
      type = lib.types.str;
      default = "Anonymous";
      description = "Folding@home donor name.";
    };

    teamNumber = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 0;
      description = "Team number to fold for (0 = no team).";
    };

    machineName = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Machine name reported to the Folding@home account service.";
    };

    cpus = lib.mkOption {
      type = with lib.types; nullOr (ints.between 0 4096);
      default = null;
      description = ''
        Number of CPU threads to fold on. The client default reserves one
        core for the system; set it to the full thread count for a machine
        that exists to make heat. 0 disables CPU slots entirely — the GPU
        folds alone while the CPUs are on other duty (a footage render).
      '';
    };

    gpuUsage = lib.mkOption {
      type = with lib.types; nullOr (ints.between 0 100);
      default = null;
      example = 50;
      description = ''
        Percent of the time the GPU slot folds (v8 "GPU usage" setting;
        multiples of 25 are what the GUI offers). The core interleaves
        idle windows, so it is a duty-cycle throttle on GPU wattage and
        heat — the only power knob a GeForce card without NVML power
        limits has. Null = the client default (100 %).
        Note: v8.5.6 logs "Unrecognized option 'gpu-usage'" when seeding
        from config.xml, so treat it as inert on new clients and use
        {option}`services.folding-at-home-native.enableGpu` or the panel's
        NVML cap where those work.
      '';
    };

    enableGpu = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether the boot-time configure oneshot enables the detected GPUs
        (the fah-provision default) or explicitly clears the group's GPU
        list (`--no-gpus`) so the box folds CPU-only. False is for hosts
        where GPU fold load trips the power supply — hp-z240-xeon-1240v6
        (240 W SFF PSU: power.limit reads 100 W while the card actually
        draws 187 W at 99 % util and the box browns out).
      '';
    };

    startDelay = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      example = "90";
      description = ''
        Shell sleep expression to wait before ExecStart, so the load step
        of spinning up every slot does not collide with the rest of boot
        (useful on boxes with marginal power supplies, where the combined
        inrush trips a brownout reset). Null = start as soon as systemd
        can.
      '';
    };

    httpAddresses = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ "127.0.0.1:7396" ];
      description = ''
        Addresses the client's Web Control/API listens on. Remote management
        through https://app.foldingathome.org works without exposing this
        (it connects out via the account token).
      '';
    };

    allowAddresses = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ "127.0.0.1" ];
      description = "Client addresses allowed to connect to the Web Control/API.";
    };

    accountTokenFile = lib.mkOption {
      type = with lib.types; nullOr path;
      default = null;
      example = lib.literalExpression "config.sops.secrets.fah_account_token.path";
      description = ''
        File containing the Folding@home account token (link this machine to
        an account). Read at activation time so the token never enters the
        Nix store or the process command line.
      '';
    };

    pauseFolding = lib.mkOption {
      type = lib.types.bool;
      # On for the whole heater fleet: these boxes exist to make heat, so the
      # fleet default is to idle them through the expensive midday window.
      default = true;
      description = ''
        Pause Folding@home during a daily expensive-electricity window
        ({option}`services.folding-at-home-native.pauseStart` to
        {option}`services.folding-at-home-native.pauseEnd`). On by default for
        every host that enables this module; set it false on a host that should
        fold around the clock.
      '';
    };

    pauseStart = lib.mkOption {
      type = lib.types.str;
      default = "10:00";
      example = "10:00";
      description = ''
        Local (system timezone, so DST-aware) time folding pauses, in the form
        systemd `OnCalendar` accepts. Inclusive: fah-client is stopped here.
      '';
    };

    pauseEnd = lib.mkOption {
      type = lib.types.str;
      default = "14:00";
      example = "14:00";
      description = ''
        Local time folding resumes (fah-client is started — unless a
        `llama-server.service` GPU lease is active, in which case folding is
        left down rather than stealing the card back). Exclusive.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.fah = {
      uid = 7396; # same id the container deployment uses
      group = "fah";
      isSystemUser = true;
    };
    users.groups.fah.gid = 7396;

    systemd.services.fah-client = {
      description = "Folding@home client (v8)";
      documentation = [
        "https://foldingathome.org"
        "https://github.com/FoldingAtHome/fah-client-bastet"
      ];
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      environment = {
        OCL_ICD_VENDORS = "${fahPackages.rocm-opencl}/etc/OpenCL/vendors";
        # libOpenCL.so.1 for the client's dlopen and the GPU core; expat + zlib
        # are NEEDED by FahCore_27 itself (the client prepends the core's own
        # directory to LD_LIBRARY_PATH when spawning it).
        LD_LIBRARY_PATH = lib.makeLibraryPath [
          pkgs.ocl-icd
          pkgs.expat
          pkgs.zlib
        ];
        LD_PRELOAD = "${pkgs.stdenv.cc.cc.lib}/lib/libstdc++.so.6";
      };

      serviceConfig = {
        User = "fah";
        Group = "fah";
        # /dev/kfd (render) for HSA compute, /dev/dri (video) for the DRM node.
        SupplementaryGroups = [
          "render"
          "video"
        ];
        StateDirectory = "fah-client";
        WorkingDirectory = "/var/lib/fah-client";
        ExecStartPre = [
          "+${installConfig}"
        ]
        ++ lib.optionals (cfg.startDelay != null) [ "+${pkgs.bash}/bin/bash -c 'sleep ${cfg.startDelay}'" ];
        # --config defaults to ./config.xml, which the ExecStartPre just wrote.
        ExecStart = "${fahPackages.fah-client}/bin/fah-client";
        Restart = "always";
        RestartSec = 10;
        # A startDelay's sleep runs inside ExecStartPre, which the default
        # 90 s start timeout would otherwise kill before ExecStart.
        TimeoutStartSec = 300;
        # SIGTERM the client only: it checkpoints work units, then exits.
        # Anything left behind gets the delayed SIGKILL.
        KillMode = "mixed";
        TimeoutStopSec = 120;
        PrivateTmp = true;
        ProtectHome = true;
      };
    };

    # A fresh v8 client starts paused with every GPU disabled (its bundled
    # group.json defaults); Web Control buttons are the intended UX. This
    # oneshot sends the equivalent websocket commands: enable every supported
    # GPU in the default resource group and start folding. Idempotent, and
    # the state persists in the client DB, so it only bites on first start
    # (or after wiping /var/lib/fah-client).
    systemd.services.fah-client-configure = {
      description = "Enable GPUs and start folding on the local Folding@home client";
      wantedBy = [ "multi-user.target" ];
      after = [ "fah-client.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "fah-client-configure" ''
          set -u
          for _ in $(seq 1 30); do
            ${fahPackages.fah-provision}/bin/fah-provision ${
              lib.optionalString (!cfg.enableGpu) "--no-gpus "
            }'${provisionAddress}' && exit 0
            sleep 2
          done
          echo "fah-client did not come up; could not configure folding" >&2
          exit 1
        '';
      };
    };

    # Upstream ships this polkit rule in its .deb (for user "fah-client");
    # it lets the client honour its keep-awake setting without the
    # "Failed to prevent sleep: Access denied" exception in the log.
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.login1.inhibit-block-sleep" &&
            subject.user == "fah") {
          return polkit.Result.YES;
        }
      });
    '';

    # Daily electricity-saving window: keep fah-client stopped between
    # pauseStart and pauseEnd. A single idempotent oneshot reads the wall clock
    # and issues stop or start, so it is safe to fire on every trigger. The
    # timer fires at both edges of the window; Persistent makes a run that was
    # missed while the box was down (e.g. a reboot inside the window) fire on
    # the next activation, so the heater stays paused for the whole window
    # instead of folding all afternoon after a midday reboot.
    systemd.services."fah-pause-window" = lib.mkIf cfg.pauseFolding {
      description = "Apply the Folding@home peak-hours pause window";
      # After fah-client so that, on a boot inside the window, this stop wins
      # over the unit's own wantedBy=multi-user.target start.
      after = [ "fah-client.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "fah-pause-window" ''
          set -eu
          systemctl=${pkgs.systemd}/bin/systemctl
          # Minutes since midnight. 10# forces base-10 so a leading zero
          # ("08", "00") is never read as octal by the shell.
          now=$((10#$(date +%H) * 60 + 10#$(date +%M)))
          start='${cfg.pauseStart}'
          end='${cfg.pauseEnd}'
          s=$((10#''${start%:*} * 60 + 10#''${start#*:}))
          e=$((10#''${end%:*} * 60 + 10#''${end#*:}))
          if [ "$now" -ge "$s" ] && [ "$now" -lt "$e" ]; then
            systemctl stop fah-client.service
          elif systemctl is-active --quiet llama-server.service; then
            echo "fah-client left stopped: llama-server.service (gpu-mode llm) is active"
          else
            systemctl start fah-client.service
          fi
        '';
      };
    };
    systemd.timers."fah-pause-window" = lib.mkIf cfg.pauseFolding {
      description = "Trigger the Folding@home pause window at its edges (${cfg.pauseStart}-${cfg.pauseEnd})";
      wantedBy = [ "timers.target" ];
      # Same-stem units are connected only by systemd's implicit Wants; state it
      # explicitly so the trigger is visible in the rendered timer.
      wants = [ "fah-pause-window.service" ];
      timerConfig = {
        OnCalendar = [
          cfg.pauseStart
          cfg.pauseEnd
        ];
        Persistent = true;
      };
    };
  };
}
