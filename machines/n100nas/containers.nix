{ config, lib, pkgs, modulesPath, ... }:


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
    unifi = {
      hostname = "unifi";
      image = "jacobalberty/unifi";
      autoStart = true;
      # ports = [
      #   "8081:8081"
      #   "8443:8443"
      #   "3478:3478/udp"
      # ];
      volumes = [
        "/srv/unifi:/unifi"
      ];
      environment = {
        TZ = "Europe/London";
      };
      extraOptions = [
        "--network=host"
        "--privileged"
      ];
    };

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
        "/sas-16tb/ds-public/Media:/Media:ro"
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
