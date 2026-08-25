# gc-business Rust worker node (gc-node) as a systemd service.
#
# gc-node is a pure control-plane client: it connects outbound to a gc-server
# over a bidirectional gRPC stream, registers this machine's capacity, receives
# WebAssembly jobs, downloads and SHA-256-verifies artifacts, executes them
# with Wasmtime (epoch-interruption timeouts), and reports progress/results
# and heartbeats back over the control stream. It exposes no inbound network
# API of its own.
#
# Stateless-host note: the Pi 5 root is tmpfs (the Nix store is a read-only NFS
# mount), so the enrollment token (~/.gc-node/token) and the artifact cache are
# lost on every reboot. gc-node therefore needs `services.gcNode.joinCode`
# again after each boot — without a token or join code it logs
# "no token and no join code; not starting worker" and exits 0.
{
  config,
  lib,
  gcNodePkg,
  ...
}:

let
  cfg = config.services.gcNode;
in
{
  options.services.gcNode = {
    enable = lib.mkEnableOption "the gc-business Rust worker node (gc-node)";

    package = lib.mkOption {
      type = lib.types.package;
      default = gcNodePkg;
      description = "The gc-node package to run.";
    };

    grpcAddr = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        gc-server gRPC address. An IP literal selects plaintext; a hostname
        selects TLS (port 443 default). Empty selects mDNS discovery of
        `_gc-server._tcp.local.` (one bounded 10 s pass, not retried).
      '';
    };

    nodeId = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Node identifier reported to the server; empty = random UUID.";
    };

    joinCode = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        First-time enrollment join code (exposed as GC_NODE_JOIN_CODE).
        Required on this stateless host on every boot, because the persisted
        token lives on the tmpfs root and does not survive a reboot.
      '';
    };

    cacheDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/gc-node/cache";
      description = "WASM artifact cache directory (volatile, on tmpfs).";
    };

    enableReconnectBackoff = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Jittered (20%) exponential reconnect backoff after stream failures.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."gc-node/config.yaml".text = ''
      server:
        grpc_addr: "${cfg.grpcAddr}"
      node:
        id: "${cfg.nodeId}"
        cache_dir: "${cfg.cacheDir}"
      features:
        enable_stream_reconnect_backoff: ${lib.boolToString cfg.enableReconnectBackoff}
    '';

    systemd.services.gc-node = {
      description = "gc-business Rust worker node";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      environment = {
        # An empty GC_NODE_JOIN_CODE is filtered out by gc-node itself, so it
        # is safe to always set this from the option.
        GC_NODE_JOIN_CODE = cfg.joinCode;
      };

      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/gc-node --headless --config /etc/gc-node/config.yaml";
        Restart = "on-failure";
        RestartSec = "10s";
        # Volatile state dir for the artifact cache; recreated fresh on every
        # boot by systemd (the root filesystem is tmpfs anyway).
        StateDirectory = "gc-node";
        StateDirectoryMode = "0700";
      };
    };
  };
}
