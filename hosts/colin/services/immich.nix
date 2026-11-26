{
  config,
  lib,
  pkgs,
  nixpkgs_25_11,
  modulesPath,
  ...
}:

let
  constants = import ../constants.nix;
  # Transitional pin (see hosts/colin/README.md): nixos-unstable ships Immich
  # 3.x, which requires a VectorChord database migration. Until that is done as
  # its own step, keep the running 2.6.1 package from the 25.11 pin. On the
  # 25.11 output this is the same derivation as pkgs.immich, so the verbatim
  # port stays bit-for-bit.
  pkgs25 = nixpkgs_25_11.legacyPackages.${pkgs.stdenv.hostPlatform.system};
in
{
  services.immich = {
    enable = true;
    package = pkgs25.immich;
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
