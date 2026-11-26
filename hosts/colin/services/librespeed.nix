{ config, lib, pkgs, modulesPath, ... }:

let
  constants = import ../constants.nix;
  RENDER_GID = "303";
in
{
  users.users.librespeed = {
    uid = constants.LIBRESPEED;
    group = "users";
    isNormalUser = true;
  };

  virtualisation.oci-containers.containers = {
    librespeed = {
      hostname = "librespeed";
      image = "ghcr.io/librespeed/speedtest:latest";
      autoStart = true;
      ports = [
        "${toString constants.LIBRESPEED}:80"
      ];
      environment = {
        TZ = "Europe/London";
      };
    };
  };

  services.nginx.virtualHosts = {
    "speed.${constants.BASE_DOMAIN}" = {
      serverAliases = [ "speed.www.${constants.BASE_DOMAIN}" ];
      useACMEHost = "${constants.BASE_DOMAIN}";
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString constants.LIBRESPEED}";
        recommendedProxySettings = true;
        proxyWebsockets = true;
      };
    };
  };
}
