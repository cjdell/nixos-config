{ config, lib, pkgs, modulesPath, ... }:

let
  # Define a single data structure for DB names and passwords.
  DATABASES = {
    immich = "immich";
  };

  PG_AUTH = ''
    #type   database  DBuser  auth-method
    local   all       all     trust
    host    sameuser  all     127.0.0.1/32          scram-sha-256
    host    sameuser  all     ::1/128               scram-sha-256
    host    sameuser  all     192.168.0.0/16        scram-sha-256
    host    sameuser  all     10.47.0.0/16          scram-sha-256
    host    sameuser  all     2001:8b0:1d14::0/48   scram-sha-256
    host    sameuser  all     2a02:8010:6680::0/48  scram-sha-256
    host    sameuser  all     2a00:23c8:b0ac::0/48  scram-sha-256
  '';
in
{
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_16;
    enableTCPIP = true;

    # Define a single data structure for DB names and passwords.
    ensureDatabases = lib.attrNames DATABASES;
    ensureUsers = lib.mapAttrsToList (db: _: {
      name = db;
      ensureDBOwnership = true;
    }) DATABASES;

    settings = {
      ssl = true;
    };

    authentication = pkgs.lib.mkOverride 10 PG_AUTH;

    dataDir = "/samsung-4tb/ds-postgres/data";

    extensions = ps: with ps; [ ps.pgvecto-rs ];
    settings = {
      shared_preload_libraries = [ "vectors.so" ];
      search_path = "\"$user\", public, vectors";
    };
  };

  # journalctl -u postgres-cert
  systemd.services.postgres-cert =
    {
      script = ''
        mkdir -p ~postgres
        chown -R postgres:postgres ~postgres
        cd ~postgres
        if [ -f PG_VERSION ]; then
          if [ ! -f server.crt ]; then
            ${pkgs.sudo}/bin/sudo -u postgres ${pkgs.openssl}/bin/openssl req -new -x509 -days 3650 -nodes -text -out server.crt -keyout server.key -subj "/CN=N100-NAS.grafton.lan"
            chmod og-rwx server.key
          else
            echo "Postgres Cert already exists"
          fi
        else
          echo "Postgres directory not available yet"
        fi
      '';
      requiredBy = [ "postgresql.service" ];
      serviceConfig = {
        Type = "oneshot";
      };
    };

  # journalctl -u postgres-set-password
  systemd.services.postgres-set-password =
    let
      generateSql = db: password: ''
        DO
        $do$
        BEGIN
          IF EXISTS (
            SELECT FROM pg_catalog.pg_roles WHERE rolname = '${db}'
          ) THEN
            ALTER USER ${db} WITH PASSWORD '${password}';
            RAISE NOTICE 'Set password for user "${db}".';
          END IF;
        END
        $do$;
      '';
      fullSql = builtins.concatStringsSep "\n" (lib.mapAttrsToList generateSql DATABASES);
    in
    {
      script = ''
        sleep 3
        ${pkgs.postgresql_16}/bin/psql -U postgres <<'EOF'
          ${fullSql}
        EOF
      '';
      requires = [ "postgresql.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
      };
    };
}

## Open a PSQL shell to the database
# sudo -u postgres psql door_system

## Dump schema for the "user" table
# sudo -u postgres pg_dump -st user door_system

## First time setup of PostgreSQL certificate
# cd ~postgres
# sudo -u postgres openssl req -new -x509 -days 3650 -nodes -text -out server.crt -keyout server.key -subj "/CN=services1.int.leighhack.org"
# chmod og-rwx server.key
# systemctl restart postgresql
# journalctl -u postgresql.service
