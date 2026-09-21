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
  # services.foldingathome = {
  #   enable = true;
  #   user = "cjdell";
  #   team = 236565;
  #   extraArgs = [
  #     "--http-addresses=0.0.0.0:7396"
  #     "--allow=0/0"
  #   ];
  # };

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

  # The FAH account token is a sops secret (secrets/fah.yaml, encrypted to the
  # key in .sops.yaml) instead of `builtins.readFile` of an absolute path. That
  # read made every host importing this file need `--impure` — `secrets/` is
  # outside the flake source, so a pure build refused it — and it baked the
  # token into the world-readable store as part of the container's environment.
  #
  # The container receives it through an env file rather than `environment = {}`:
  # a sops secret only exists after activation (too late for the container's
  # environment to be built from it), and its path must stay outside the store.
  sops.secrets."fah_account_token" = {
    sopsFile = ../secrets/fah.yaml;
    # A rotated token only reaches the running container once it is recreated.
    restartUnits = [ "podman-fah.service" ];
  };

  sops.templates."fah-env" = {
    owner = "root";
    mode = "0400";
    content = ''
      ACCOUNT_TOKEN=${config.sops.placeholder.fah_account_token}
    '';
  };

  # Containers start at `multi-user.target` and `sops-install-secrets.service`
  # runs during sysinit, so the order is already right in practice; stating it
  # keeps a container from starting (and failing) without its env file.
  systemd.services.podman-fah = {
    wants = [ "sops-install-secrets.service" ];
    after = [ "sops-install-secrets.service" ];
  };

  virtualisation.containers.enable = true;

  virtualisation.oci-containers.backend = "podman";

  virtualisation.oci-containers.containers = {
    fah = {
      hostname = "fah";
      image = "linuxserver/foldingathome";
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
      environmentFiles = [ config.sops.templates."fah-env".path ];
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
