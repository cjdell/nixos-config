# dsh-web-service — the forked DeepSeek Harness Web GUI as an always-on systemd
# service, served directly on the LAN.
#
# Why a fork: stock `dsh web` refuses `--host 0.0.0.0`, and its /api fence 403s
# any non-loopback Host/Origin, which is why this repo ran `dsh-web proxy`
# (common/dsh-web-proxy.mjs — a TCP proxy that rewrote Host to loopback, and
# even then the GUI's privileged surfaces stayed inert: the browser classified
# a LAN page as a foreign machine, so Settings → Models failed with "settings
# are unavailable in this browser"). The fork in `inputs.deepseek-harness`
# (~/Projects/deepseek-harness, branch trusted-authority-surface) makes a
# *declared* authority the operator's own surface, so the GUI is reachable on
# the machine's own address and Settings works there. No proxy, no header
# rewriting. See docs/dsh-fork/ for the patch, the diagnosis, and the build.
#
# The fork's own flake builds the whole workspace (pnpm install + build) into
# one self-contained package: `$dsh/bin/dsh` embeds the Node it was built
# with, and the rest of the package is the built tree the CLI resolves its
# workspace dependencies through. This module only runs it.
#
# Settings are per machine: `settingsIp` names this host, and the settings
# document is `settings-<ip>.yaml`, so machines sharing a settings directory
# (or several services in one home) keep separate documents.
#
# The service deliberately runs as a normal user with no sandbox: the GUI's
# agents execute commands in that user's workspaces.
{ config, lib, pkgs, inputs, ... }:

let
  cfg = config.services.dshWebHarness;
  inherit (lib) mkEnableOption mkIf mkOption types;

  # The profile's patch layer, applied after every bundle layer. The `settings`
  # row is `@deepseek-ai/dsh-settings-file` in the base bundle patch; a patch
  # replaces that row's whole config, and the row has none of its own, so
  # setting `path` here moves this machine's settings document.
  patchLayer = pkgs.writeText "dsh-web-harness-cordis.patch.yml" ''
    # Managed by NixOS (services.dshWebHarness): the settings document of this
    # machine, named after its own address so machines that share a settings
    # directory keep one document each.
    - id: settings
      config:
        path: ${cfg.settingsDocument}
  '';
in
{
  options.services.dshWebHarness = {
    enable = mkEnableOption "the forked DeepSeek Harness Web GUI as a service";

    dsh = mkOption {
      type = types.package;
      default = inputs.deepseek-harness.packages.${pkgs.stdenv.hostPlatform.system}.default;
      description = ''
        The forked harness, built by its own flake (the deepseek-harness input).
        $out is the complete built workspace tree; $out/bin/dsh is the launcher.
      '';
    };

    user = mkOption {
      type = types.str;
      default = "cjdell";
      description = "User the GUI runs as — and therefore the account its agents work in.";
    };

    group = mkOption {
      type = types.str;
      default = "users";
      description = "Group of the harness home and settings document.";
    };

    home = mkOption {
      type = types.path;
      default = "/home/cjdell";
      description = "The user's home, used for HOME.";
    };

    dshHome = mkOption {
      type = types.path;
      default = "${cfg.home}/.dsh";
      description = "Harness home (sessions, credentials, profiles, settings).";
    };

    bindHost = mkOption {
      type = types.str;
      default = "0.0.0.0";
      description = "Bind host. The fork accepts an all-interfaces bind only together with at least one trustedHosts entry.";
    };

    port = mkOption {
      type = types.port;
      default = 3080;
      description = "Listen port (the port the old proxy forwarded to).";
    };

    trustedHosts = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "192.168.49.1" ];
      description = ''
        Authorities this deployment is served under: names the /api Host fence
        admits and the browser treats as the operator's own surface. An
        IP-literal entry is port-less and matches any port.
      '';
    };

    settingsIp = mkOption {
      type = types.str;
      example = "192.168.49.1";
      description = "This machine's own address, which names its settings document.";
    };

    settingsDirectory = mkOption {
      type = types.path;
      default = cfg.dshHome;
      description = "Directory holding the settings documents.";
    };

    settingsDocument = mkOption {
      type = types.path;
      default = "${cfg.settingsDirectory}/settings-${cfg.settingsIp}.yaml";
      description = "This machine's settings document; keyed by settingsIp.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.trustedHosts != [ ];
        message = "services.dshWebHarness.trustedHosts must name at least one authority: the fork refuses --host ${cfg.bindHost} without one, and an unreachable fence leaves the GUI inert.";
      }
      {
        assertion = cfg.settingsIp != "";
        message = "services.dshWebHarness.settingsIp must be this machine's own address (it names the settings document).";
      }
    ];

    systemd.services.dsh-web-harness = {
      description = "DeepSeek Harness Web GUI (fork: declared authorities are the operator's own surface)";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];

      # Own the profile patch layer that carries this machine's settings path.
      # Absolute coreutils: preStart must not depend on the unit's PATH.
      preStart = ''
        ${pkgs.coreutils}/bin/install -d -m 0700 -o ${cfg.user} -g ${cfg.group} ${cfg.dshHome}/profiles/web
        ${pkgs.coreutils}/bin/install -m 0600 -o ${cfg.user} -g ${cfg.group} ${patchLayer} ${cfg.dshHome}/profiles/web/cordis.patch.yml
      '';

      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        # The built tree; the CLI's config trees and workspace resolution are
        # all relative to it.
        WorkingDirectory = cfg.dsh;
        Environment = [
          "HOME=${cfg.home}"
          "DSH_HOME=${cfg.dshHome}"
          # The package's launcher (embeds its own Node) plus the userland the
          # GUI's agents invoke by name. This Environment overrides systemd's
          # default PATH, so everything they need must be listed here.
          "PATH=${
            lib.makeBinPath [
              cfg.dsh
              pkgs.coreutils
              pkgs.git
              pkgs.bashInteractive
              pkgs.nodejs_24
              pkgs.findutils
              pkgs.gnugrep
              pkgs.gnused
              pkgs.gawk
              pkgs.procps
              pkgs.which
            ]
          }"
        ];
        # --trusted-host is variadic, so it comes last; --no-open keeps headless
        # service starts from trying to launch a browser.
        ExecStart = lib.concatStringsSep " " (
          [
            "${cfg.dsh}/bin/dsh"
            "web"
            "--host"
            cfg.bindHost
            "--port"
            (toString cfg.port)
            "--no-open"
            "--trusted-host"
          ]
          ++ cfg.trustedHosts
        );
        Restart = "always";
        RestartSec = "10s";
      };
    };
  };
}
