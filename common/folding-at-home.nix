isNvidia:

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
        ACCOUNT_TOKEN = (builtins.readFile "/home/cjdell/nixos-config/secrets/fah-account-token.txt");
        MACHINE_NAME = config.networking.hostName;
      };
      extraOptions = [
        # "--device=/dev/kfd"
        "--device=/dev/dri"
        "--group-add=${RENDER_GID}"
      ]
      ++ (lib.optionals isNvidia [
        "--device=nvidia.com/gpu=all"
      ]);
    };
  };
}
