{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

let
  constants = import ../constants.nix;
in
{
  services.immich = {
    enable = true;
    host = "0.0.0.0";
    port = 2283;
    accelerationDevices = null;
    database = {
      enable = false;
    };
    mediaLocation = "/electronerds/ds-photos/immich";
    openFirewall = true;
  };

  system.activationScripts.immich-dir = ''
    mkdir -p /electronerds/ds-photos/immich
    chown immich:immich /electronerds/ds-photos/immich
  '';

  users.users.immich.extraGroups = [
    "video"
    "render"
  ];

  services.nginx.virtualHosts = {
    "photos.${constants.BASE_DOMAIN}" = {
      useACMEHost = "${constants.BASE_DOMAIN}";
      forceSSL = true;

      locations."/" = {
        proxyPass = "http://127.0.0.1:2283";
        recommendedProxySettings = true;
        proxyWebsockets = true;

        extraConfig = ''
          client_max_body_size 50000M;
          proxy_read_timeout   600s;
          proxy_send_timeout   600s;
          send_timeout         600s;
        '';
      };
    };
  };
}
