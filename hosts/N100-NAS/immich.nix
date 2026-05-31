{
  config,
  lib,
  pkgs,
  ...
}:

{
  # journalctl -u immich-server -f
  services.immich = {
    enable = true;
    host = "0.0.0.0";
    port = 2283;
    accelerationDevices = null;
    database = {
      enable = false;
      createDB = false;
    };
    settings = {
      newVersionCheck.enable = false;

      oauth = {
        autoLaunch = true;
        autoRegister = true;
        buttonText = "Login with OAuth";
        clientId = "immich";
        clientSecret = "LrxLrbUHvX2KXCJabzKfF7KvXSV55Z8pdVbdbh5a9fDWzZUt";
        defaultStorageQuota = null;
        enabled = true;
        issuerUrl = "https://kanidm.home.chrisdell.info/oauth2/openid/immich";
        mobileOverrideEnabled = false;
        # mobileRedirectUri = "app.immich:///oauth-callback";
        profileSigningAlgorithm = "none";
        roleClaim = "immich_role";
        scope = "openid email profile";
        signingAlgorithm = "ES256";
        storageLabelClaim = "preferred_username";
        # storageQuotaClaim = "immich_quota";
        timeout = 30000;
        tokenEndpointAuthMethod = "client_secret_post";
      };
    };
    mediaLocation = "/samsung-4tb/ds-photos/immich";
    openFirewall = true;
  };

  services.postgresql = {
    ensureDatabases = [ "immich" ];
    ensureUsers = [
      {
        name = "immich";
        ensureDBOwnership = true;
      }
    ];
  };

  sops.templates."postgres-immich-init-script".content = ''
    set -euo pipefail
    sleep 3;
    ${pkgs.postgresql_16}/bin/psql -U postgres -c "ALTER USER immich WITH PASSWORD '${config.sops.placeholder.immich_db_password}';"
    ${pkgs.util-linux}/bin/wall -n "Database password for immich configured"
  '';

  # journalctl -u postgres-immich-init -b
  systemd.services.postgres-immich-init = {
    requires = [ "postgresql-setup.service" ];
    after = [ "postgresql-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${lib.getExe pkgs.bash} ${config.sops.templates.postgres-immich-init-script.path}";
      RemainAfterExit = true; # Prevents this triggering everytime we switch
    };
  };

  system.activationScripts.immich-dir = ''
    mkdir -p /samsung-4tb/ds-photos/immich
    chown immich:immich /samsung-4tb/ds-photos/immich
  '';

  users.users.immich.extraGroups = [
    "video"
    "render"
  ];
}
