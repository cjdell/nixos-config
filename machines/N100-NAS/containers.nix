{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

let
  RENDER_GID = "303";
  FRIGATE_UID = 8096;
in
{
  virtualisation.podman = {
    enable = true;
    autoPrune.enable = true;
    dockerCompat = true;
    dockerSocket.enable = true;
  };

  networking.firewall.interfaces.podman0.allowedUDPPorts = [ 53 ];

  # Enable common container config files in /etc/containers
  virtualisation.containers.enable = true;

  virtualisation.oci-containers.backend = "podman";

  virtualisation.oci-containers.containers = {
    jellyfin = {
      hostname = "jellyfin";
      image = "linuxserver/jellyfin";
      autoStart = true;
      ports = [
        "8096:8096"
        "7359:7359/udp"
      ];
      volumes = [
        "/srv/jellyfin/config:/config"
        "/samsung-4tb/ds-media:/Media:ro"
      ];
      environment = {
        TZ = "Europe/London";
        PUID = toString FRIGATE_UID;
        PGID = "100";
      };
      extraOptions = [
        "--device=/dev/dri/renderD128"
        "--group-add=${RENDER_GID}"
      ];
    };
  };

  users.users.jellyfin = {
    uid = FRIGATE_UID;
    group = "users";
    isNormalUser = true;
  };

  system.activationScripts.jellyfin = ''
    # Create config and storage directories
    mkdir -p /srv/jellyfin/config

    # Ensure correct permissions
    chown -R ${toString FRIGATE_UID}:users /srv/jellyfin
    chmod -R g+rw /srv/jellyfin
  '';
}
