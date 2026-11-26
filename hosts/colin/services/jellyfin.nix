{ config, lib, pkgs, modulesPath, ... }:

let
  constants = import ../constants.nix;
in
{
  users.users.jellyfin = {
    uid = constants.JELLYFIN;
    group = "users";
    isNormalUser = true;
  };

  virtualisation.oci-containers.containers = {
    jellyfin = {
      hostname = "jellyfin";
      image = "linuxserver/jellyfin";
      autoStart = true;
      ports = [
        "${toString constants.JELLYFIN}:8096"
        "7359:7359/udp"
      ];
      volumes = [
        "/srv/jellyfin/config:/config"
        "/electronerds/ds-private/Videos:/videos"
      ];
      environment = {
        TZ = "Europe/London";
        PUID = "${toString constants.JELLYFIN}";
        PGID = "100";
      };
      extraOptions = [
        "--device=/dev/dri/renderD128"
        "--group-add=${toString constants.RENDER_GID}"
      ];
    };
  };

  services.nginx.virtualHosts = {
    "tv.${constants.BASE_DOMAIN}" = {
      serverAliases = [ "tv.www.${constants.BASE_DOMAIN}" ];
      useACMEHost = "${constants.BASE_DOMAIN}";
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString constants.JELLYFIN}";
        recommendedProxySettings = true;
        proxyWebsockets = true;
      };
    };
  };
}

