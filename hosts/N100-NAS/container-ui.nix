{
  pkgs,
  inputs,
  ...
}:

let
  # Per-system package set (nixos-utils' flake packages are nested by system).
  # Note: in a NixOS module `config.system` is the `system.*` options set, so
  # the architecture must come from `builtins.currentSystem`.
  containerUi = builtins.getAttr builtins.currentSystem inputs.nixos-utils.packages;
in
{
  # ============================================================================
  # Container UI — server-rendered web UI for managing podman containers
  # (same app as container-ui.service on grafton-router; source in the
  # nixos-utils repo, built by that flake)
  # Web UI: http://192.168.49.22:8091 (LAN / tailnet)
  #
  # Shows container state / ports / mounts / CPU / RAM, a live log tail
  # (server-sent events), and can update (pull + restart) one or many
  # containers. Runs as root because it restarts podman-systemd units and
  # uses the rootful podman setup.
  #
  # Unlike grafton-router there is no local nginx, so the service binds
  # directly on all interfaces (LAN + tailnet, like this host's other
  # services) and runs without OIDC (no Kanidm client is provisioned for
  # this URL yet).
  # ============================================================================

  systemd.services.container-ui = {
    description = "Container management web UI";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = "${containerUi.container-ui}/bin/container-ui";
    };
    environment = {
      LISTEN_ADDR = "0.0.0.0:8091";
      BASE_URL = "http://192.168.49.22:8091";
      # Absolute path: podman is not in the default service PATH (systemctl is)
      PODMAN_BIN = "${pkgs.podman}/bin/podman";
      # Same push gateway as system.updateContainers (common/system.nix)
      WEBHOOK_URL = "https://notify.home.chrisdell.info";
      RUST_LOG = "info";
    };
  };
}
