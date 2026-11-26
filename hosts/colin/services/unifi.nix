{ config, lib, pkgs, modulesPath, ... }:

let
  constants = import ../constants.nix;
in
{
  users.users.unifi = {
    uid = constants.UNIFI;
    group = "users";
    isNormalUser = true;
  };

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
        # "--pull=always"
        "--network=host"
        "--privileged"
        # "--sysctl net.ipv4.ip_unprivileged_port_start=0"
        # "--user=${toString constants.UNIFI}:100"
      ];
    };
  };

  services.nginx.virtualHosts = {
    "unifi.${constants.BASE_DOMAIN}" = {
      useACMEHost = "${constants.BASE_DOMAIN}";
      forceSSL = true;
      locations."/" = {
        proxyPass = "https://127.0.0.1:8443";
        recommendedProxySettings = true;
      };
    };
  };
}
