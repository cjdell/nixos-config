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
      ports = [
      #   "8081:8081"
        # "8443:8443"
        # "3478:3478/udp"
      ];
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
  };
}
