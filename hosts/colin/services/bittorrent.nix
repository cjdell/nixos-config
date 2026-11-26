{ config, lib, pkgs, modulesPath, ... }:

let
  constants = import ../constants.nix;
  RENDER_GID = "303";
in
{
  users.users.bittorrent = {
    uid = constants.BITTORRENT;
    group = "users";
    isNormalUser = true;
  };

  virtualisation.oci-containers.containers = {
    bittorrent = {
      hostname = "bittorrent";
      image = "linuxserver/qbittorrent:latest";
      autoStart = true;
      ports = [
        "${toString constants.BITTORRENT}:${toString constants.BITTORRENT}"
        "6881:6881/tcp"
        "6881:6881/udp"
      ];
      volumes = [
        "/srv/bittorrent/config:/config"
        "/electronerds/ds-private/Downloads:/downloads"
      ];
      environment = {
        TZ = "Europe/London";
        PUID = "${toString constants.BITTORRENT}";
        PGID = "100";
        WEBUI_PORT = "${toString constants.BITTORRENT}";
        TORRENTING_PORT = "6881";
        UMASK = "002";
      };
    };
  };

  services.nginx.virtualHosts = {
    "bittorrent.${constants.BASE_DOMAIN}" = {
      serverAliases = [ "bittorrent.www.${constants.BASE_DOMAIN}" ];
      useACMEHost = "${constants.BASE_DOMAIN}";
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString constants.BITTORRENT}";
        recommendedProxySettings = true;
      };
    };
  };
}
