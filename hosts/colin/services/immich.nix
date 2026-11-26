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

  # The `immich` role owns the database but is not a superuser, and
  # services.immich.database is off (external PG). Immich 3 needs the vchord
  # extension created before it starts; do it as postgres, idempotently.
  # journalctl -u immich-vectorchord-init
  systemd.services.immich-vectorchord-init = {
    description = "Create the VectorChord extension in the Immich database";
    wantedBy = [ "multi-user.target" ];
    after = [ "postgresql.service" ];
    requires = [ "postgresql.service" ];
    before = [ "immich-server.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
      RemainAfterExit = true;
    };
    script = ''
      ${pkgs.postgresql_16}/bin/psql -d immich -v ON_ERROR_STOP=1 \
        -c 'CREATE EXTENSION IF NOT EXISTS vchord CASCADE;'
    '';
  };

  # Order the server behind it, and fail fast rather than let Immich spin on a
  # database without the extension.
  systemd.services.immich-server = {
    requires = [ "immich-vectorchord-init.service" ];
    after = [ "immich-vectorchord-init.service" ];
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
