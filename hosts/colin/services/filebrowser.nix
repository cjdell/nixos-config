{ config, lib, pkgs, modulesPath, ... }:

let
  constants = import ../constants.nix;
in
{
  virtualisation.oci-containers.containers = {
    filebrowser = {
      hostname = "filebrowser";
      image = "hurlenko/filebrowser";
      autoStart = true;
      ports = [
        "${toString constants.FILE_BROWSER}:8080"
      ];
      volumes = [
        "/electronerds/ds-private:/data"
        "/srv/filebrowser/config:/config"
      ];
      environment = {
        TZ = "Europe/London";
        UMASK = "002";
      };
      extraOptions = [
        "--user=${toString constants.ADMIN_UID}:100"
      ];
    };
  };

  services.nginx.virtualHosts = {
    "files.${constants.BASE_DOMAIN}" = {
      serverAliases = [ "files.www.${constants.BASE_DOMAIN}" ];
      useACMEHost = "${constants.BASE_DOMAIN}";
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString constants.FILE_BROWSER}";
        recommendedProxySettings = true;
      };
    };
  };
}
