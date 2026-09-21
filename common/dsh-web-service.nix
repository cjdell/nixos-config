# dsh-web-service — the forked DeepSeek Harness Web GUI as an always-on systemd
# service, served directly on the LAN.
#
# Why a fork: stock `dsh web` refuses `--host 0.0.0.0`, and its /api fence 403s
# any non-loopback Host/Origin, so this repo first ran `dsh-web proxy` (the
# retired common/dsh-web{,.sh,-proxy.mjs} — a TCP proxy that rewrote Host to
# loopback) and even then the GUI's privileged surfaces stayed inert: the
# browser classified a LAN page as a foreign machine, so Settings → Models
# failed with "settings are unavailable in this browser". The fork in
# `inputs.deepseek-harness` (github:cjdell/deepseek-harness, branch
# trusted-authority-surface) makes a *declared* authority the operator's own
# surface, so the GUI is reachable on the machine's own address and Settings
# works there. No proxy, no header rewriting. See docs/dsh-fork/ for the patch,
# the diagnosis, and the build.
#
# The fork's own flake builds the whole workspace into one self-contained
# package: it fetches the lockfile's dependencies with `fetchPnpmDeps`, runs
# `pnpm run build` offline in the sandbox, and `$dsh/bin/dsh` embeds the Node
# it was built with; the rest of the package is the built tree the CLI
# resolves its workspace dependencies through. No local checkout is needed
# and the flake evaluates purely (no `--impure`). This module only runs it.
#
# Signing in: `dsh web` mints a random launch token per process and prints one
# URL carrying it, so the bare `http://<host>:<port>/` answers 401 until a
# browser has opened that URL. `dsh-web-url` (installed below) prints the live
# one and `dsh-web-url --open` opens it — no journal archaeology. The token is
# only the bootstrap: what it mints is a signed cookie whose secret is durable
# and whose lifetime is `cookieMaxAgeDays`, so a browser signs in once per
# machine and then reaches the GUI at the plain URL — bookmark that.
#
# Settings are per machine: `settingsIp` names this host, and the settings
# document is `settings-<ip>.yaml`, so machines sharing a settings directory
# (or several services in one home) keep separate documents.
#
# The service deliberately runs as a normal user with no sandbox: the GUI's
# agents execute commands in that user's workspaces.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

let
  cfg = config.services.dshWebHarness;
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  # The nixos-utils rollback module installs nixos-confirm (the deploy
  # workflow's "I am alive, don't roll back" step) into systemPackages on
  # autoRollback hosts — but as a package local to that module, no other
  # module can reference it. Wrap the system copy so the
  # agents' PATH carries it by name on those hosts; on hosts without
  # autoRollback the command simply is not there, as today.
  nixosConfirm = pkgs.writeShellScriptBin "nixos-confirm" ''
    exec /run/current-system/sw/bin/nixos-confirm "$@"
  '';

  # attrByPath (not config.system.autoRollback.enable) so this module also
  # evaluates on hosts that don't import the rollback module at all.
  autoRollbackEnabled = lib.attrByPath [ "system" "autoRollback" "enable" ] false config;

  # The URL that signs a browser in. `dsh web` mints its launch token per
  # process and prints it only to stdout (the journal), so this reads the live
  # one back out — the token is a bootstrap credential, not a thing to hunt for
  # with journalctl by hand. `--local` picks the loopback URL, `--open` hands it
  # to the desktop browser.
  urlCommand = pkgs.writeShellScriptBin "dsh-web-url" ''
    set -euo pipefail

    unit="dsh-web-harness"
    open=0
    want=lan
    for arg in "$@"; do
      case "$arg" in
        --open) open=1 ;;
        --local) want=local ;;
        -h|--help)
          echo "usage: dsh-web-url [--local] [--open]"
          exit 0
          ;;
        *)
          echo "dsh-web-url: unknown option: $arg" >&2
          exit 2
          ;;
      esac
    done

    # One line per start; the newest is the live process.
    line=$(journalctl -u "$unit" --no-pager --output=cat -n 5000 2>/dev/null \
      | grep -e 'dsh web: ' | tail -n 1 || true)
    if [ -z "$line" ]; then
      echo "dsh-web-url: no startup URL in '$unit' yet — is it running?" >&2
      exit 1
    fi

    # "dsh web: http://127.0.0.1:3080/?token=… (LAN: http://192.168.49.50:3080/?token=…)"
    local_url=$(printf '%s\n' "$line" | sed -n 's/^dsh web: \([^ ]*\).*$/\1/p')
    lan_url=$(printf '%s\n' "$line" | sed -n 's/.*(LAN: \([^)]*\)).*$/\1/p')
    if [ -z "$local_url" ]; then
      echo "dsh-web-url: cannot parse the startup URL: $line" >&2
      exit 1
    fi

    url="$local_url"
    if [ "$want" = lan ] && [ -n "$lan_url" ]; then url="$lan_url"; fi

    if [ "$open" = 1 ]; then
      if command -v xdg-open >/dev/null 2>&1; then
        exec xdg-open "$url"
      fi
      echo "dsh-web-url: xdg-open is not on PATH; open this URL yourself:" >&2
    fi
    printf '%s\n' "$url"
  '';

  # The profile's patch layer, applied after every bundle layer. A patch
  # replaces the matched row's whole `config`, so each row here restates what
  # it must keep:
  #
  #   settings   — `@deepseek-ai/dsh-settings-file` has no config of its own in
  #                the base bundle, so `path` alone moves this machine's
  #                settings document.
  #   connection — `@deepseek-ai/dsh-client-connection` carries the trustedHosts
  #                expression, which is repeated verbatim: dropping it would
  #                leave the row with only cookieMaxAgeDays, and with no declared
  #                authority the /api fence 403s every LAN request.
  patchLayer = pkgs.writeText "dsh-web-harness-cordis.patch.yml" ''
    # Managed by NixOS (services.dshWebHarness): the settings document of this
    # machine, named after its own address so machines that share a settings
    # directory keep one document each.
    - id: settings
      config:
        path: ${cfg.settingsDocument}

    # Browser sessions are meant to outlive the process that minted them: the
    # cookie's signing secret is durable, so the cookie — not the per-process
    # token — is what makes the plain URL work. Upstream defaults to 30 days;
    # a machine that has signed in once stays signed in for this long.
    - id: connection
      config:
        trustedHosts: !!js ctx.webRuntime.trustedHosts
        cookieMaxAgeDays: ${toString cfg.cookieMaxAgeDays}
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

    cookieMaxAgeDays = mkOption {
      type = types.ints.positive;
      default = 3650;
      example = 30;
      description = ''
        How long a browser stays signed in (in days) after opening the startup
        token URL `dsh-web-url` prints — i.e. how long the plain
        `http://<host>:<port>/` keeps working in that browser. The cookie is
        bound to the authority it was minted for and signed with a durable
        secret, so it survives service restarts. Upstream's default is 30.
      '';
    };
  };

  config = mkIf cfg.enable {
    # The way in: `dsh-web-url` prints the live sign-in URL, so getting a
    # browser past the 401 is one command instead of a journal grep.
    environment.systemPackages = [ urlCommand ];

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
          #
          # The list mirrors a normal user shell, so agents running through
          # the GUI meet the same tools the operator's terminal does: fast
          # search (ripgrep/fd), JSON and scripting (jq/python3 — the
          # documented `nix shell nixpkgs#python3` workaround), the nix CLI
          # (flake check/eval of this repo), network (curl/ssh/rsync/openssl),
          # archives (tar/zip), inspection (file/hexdump/lsblk/tree/less), and
          # system administration — systemctl/journalctl for the deploy and
          # service workflow, nixos-rebuild for --flake rebuilds, hostname and
          # ldd from the operator's shell.
          #
          # nixos-confirm (autoRollback hosts only) comes from a wrapper: the
          # rollback module builds it locally, so it is not referenceable.
          # /run/wrappers/bin is appended last: the store's sudo is not setuid
          # on this system, and the wrappers hold the setuid copies the
          # deploy workflow (sudo nixos-rebuild + sudo nixos-confirm) needs —
          # sudo has no secure_path here, so it resolves commands from this
          # very PATH.
          "PATH=${
            lib.makeBinPath (
              [
                cfg.dsh
                # Shell and basics.
                pkgs.bashInteractive
                pkgs.coreutils
                pkgs.git
                pkgs.nodejs_24
                pkgs.findutils
                pkgs.gnugrep
                pkgs.gnused
                pkgs.gawk
                pkgs.diffutils
                pkgs.procps
                pkgs.which
                # Fast search.
                pkgs.ripgrep
                pkgs.fd
                # JSON and scripting.
                pkgs.jq
                pkgs.python3
                # This repo is Nix: agents should be able to check what they
                # change without a `nix shell`.
                pkgs.nix
                # Network (the AGENTS.md API and cross-host workflows).
                pkgs.curl
                pkgs.openssh
                pkgs.rsync
                pkgs.openssl
                # Archives.
                pkgs.gnutar
                pkgs.zip
                pkgs.unzip
                # System administration (the deploy workflow: check and
                # restart services, read their journals, rebuild the flake).
                pkgs.systemd
                pkgs.nixos-rebuild
                # Inspection.
                pkgs.file
                pkgs.util-linux
                pkgs.tree
                pkgs.less
                # ldd/iconv/locale: glibc's bin split (the main output has no
                # bin/ at all), hostname: the operator's shell gets it from
                # inetutils (the util-linux split above carries no hostname).
                pkgs.glibc.bin
                pkgs.inetutils
              ]
              # autoRollback hosts: the deploy workflow's confirm step.
              ++ lib.optionals autoRollbackEnabled [ nixosConfirm ]
            )
          }:/run/wrappers/bin"
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
