{ config, lib, pkgs, modulesPath, ... }:

let
  constants = import ../constants.nix;
in
{
  virtualisation.oci-containers.containers = {
    whoogle = {
      hostname = "whoogle";
      image = "benbusby/whoogle-search";
      autoStart = true;
      ports = [
        "${toString constants.WHOOGLE}:5000"
      ];
      environment = {
        TZ = "Europe/London";
      };
    };
  };

  services.nginx.virtualHosts = {
    "search.${constants.BASE_DOMAIN}" = {
      serverAliases = [ "search.www.${constants.BASE_DOMAIN}" ];
      useACMEHost = "${constants.BASE_DOMAIN}";
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString constants.WHOOGLE}";
        recommendedProxySettings = true;
      };
    };
  };
}
