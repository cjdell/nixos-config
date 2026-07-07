{ config, utils, ... }:
let
  # Write compiled config file here...
  configFile = "/run/immich.json";
  # Config file which includes SOPS secrets...
  secretsReplacement = (
    utils.genJqSecretsReplacement { } {
      newVersionCheck.enable = false;
      oauth = {
        autoLaunch = true;
        autoRegister = true;
        buttonText = "Login with OAuth";
        clientId = "immich";
        clientSecret._secret = "${config.sops.secrets.immich_oidc_client_secret.path}";
        defaultStorageQuota = null;
        enabled = true;
        issuerUrl = "https://kanidm.home.chrisdell.info/oauth2/openid/immich";
        mobileOverrideEnabled = false;
        profileSigningAlgorithm = "none";
        roleClaim = "immich_role";
        scope = "openid email profile";
        signingAlgorithm = "ES256";
        storageLabelClaim = "preferred_username";
        timeout = 30000;
        tokenEndpointAuthMethod = "client_secret_post";
      };
    } configFile
  );
in
{
  # journalctl -u immich-secrets -f
  systemd.services.immich-secrets = {
    description = "Immich Secrets";
    requiredBy = [ "podman-immich-server.service" ];
    before = [ "podman-immich-server.service" ];
    script = secretsReplacement.script;
  };

  virtualisation.oci-containers.containers = {
    immich-server = {
      hostname = "immich-server";
      image = "ghcr.io/immich-app/immich-server:v3.0.1";
      autoStart = true;
      ports = [
        "2284:2283"
      ];
      volumes = [
        "${configFile}:/config.json" # Config file. Contains OIDC settings
        "/samsung-4tb/ds-photos/immich/upload:/data" # Native data
        "/samsung-4tb/ds-photos:/samsung-4tb/ds-photos" # External Libraries
        "/etc/localtime:/etc/localtime:ro"
      ];
      environment = {
        IMMICH_CONFIG_FILE = "/config.json"; # NOTE! Path within the container
        DB_HOSTNAME = "10.88.0.53";
        DB_USERNAME = "postgres";
        DB_PASSWORD = "postgres";
        DB_DATABASE_NAME = "immich";
        REDIS_HOSTNAME = "10.88.0.52";
      };
      extraOptions = [
        "--ip=10.88.0.50"
      ];
      dependsOn = [
        "immich-redis"
        "immich-postgres"
      ];
    };

    immich-machine-learning = {
      hostname = "immich-machine-learning";
      image = "ghcr.io/immich-app/immich-machine-learning:v3.0.1";
      autoStart = true;
      volumes = [
        "/samsung-4tb/ds-photos/immich/model-cache:/cache"
      ];
      environment = {
        DB_HOSTNAME = "10.88.0.53";
        DB_USERNAME = "postgres";
        DB_PASSWORD = "postgres";
        DB_DATABASE_NAME = "immich";
        REDIS_HOSTNAME = "10.88.0.52";
      };
      extraOptions = [
        "--ip=10.88.0.51"
      ];
    };

    immich-redis = {
      hostname = "immich-redis";
      image = "docker.io/valkey/valkey:9@sha256:4963247afc4cd33c7d3b2d2816b9f7f8eeebab148d29056c2ca4d7cbc966f2d9";
      autoStart = true;
      extraOptions = [
        "--ip=10.88.0.52"
      ];
    };

    immich-postgres = {
      hostname = "immich-postgres";
      image = "ghcr.io/immich-app/postgres:16-vectorchord0.5.3-pgvector0.8.1@sha256:971d18060781e929dc3a0b72b02e3f09ba9d146d4c00b2acac81a7ae837bbde5";
      autoStart = true;
      volumes = [
        "/samsung-4tb/ds-photos/immich/postgres:/var/lib/postgresql/data"
      ];
      environment = {
        POSTGRES_PASSWORD = "postgres";
        POSTGRES_USER = "postgres";
        POSTGRES_DB = "immich";
        POSTGRES_INITDB_ARGS = "--data-checksums";
      };
      extraOptions = [
        "--ip=10.88.0.53"
        "--shm-size=128mb"
      ];
    };
  };
}

# sudo mkdir          /samsung-4tb/ds-photos/immich/upload
# sudo mkdir          /samsung-4tb/ds-photos/immich/model-cache
# sudo mkdir          /samsung-4tb/ds-photos/immich/postgres
# sudo chmod -R +rwX  /samsung-4tb/ds-photos/immich
