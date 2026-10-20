dgpu:

{
  config,
  pkgs,
  lib,
  ...
}:

let
  FAH_UID = 7396;
  RENDER_GID = "303";
in
{
  # NOTE: nixpkgs has no `services.foldingathome` module — the native v8
  # client lives in common/folding-at-home-native.nix instead (it also folds
  # on AMD GPUs, which this image cannot see: it ships Intel/NVIDIA ICDs only).

  users.users.fah = {
    uid = FAH_UID;
    group = "fah";
    isSystemUser = true;
  };

  users.groups.fah = {
    gid = FAH_UID;
  };

  system.activationScripts.fah = ''
    # Create config and storage directories
    mkdir -p /srv/fah

    # Ensure correct permissions
    chown -R ${toString FAH_UID}:${toString FAH_UID} /srv/fah
    chmod -R g+rw /srv/fah
  '';

  virtualisation.containers.enable = true;

  virtualisation.oci-containers.backend = "podman";

  virtualisation.oci-containers.containers = {
    fah = {
      hostname = "fah";
      # Fully qualified: podman on these hosts defines no unqualified-search
      # registries, so the short name fails with "did not resolve to an alias".
      image = "docker.io/linuxserver/foldingathome";
      autoStart = true;
      ports = [
        "7396:7396"
      ];
      volumes = [
        "/srv/fah:/config"
      ];
      environment = {
        TZ = "Europe/London";
        PUID = toString FAH_UID;
        PGID = toString FAH_UID;
        NVIDIA_VISIBLE_DEVICES = "all";
        MACHINE_NAME = config.networking.hostName;
      };
      extraOptions = [
        "--device=/dev/dri"
        "--group-add=${RENDER_GID}"
      ]
      ++ (
        if dgpu == "nvidia" then
          [ "--device=nvidia.com/gpu=all" ]
        else if dgpu == "amd" then
          [ "--device=/dev/kfd" ]
        else
          [ ]
      );
    };
  };
}
