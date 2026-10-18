# Development PostgreSQL for this build machine (zen3-nixos).
#
# Currently only hass-rs's persistence layer
# (crates/home-assistant-rust, `hass-store`) uses it: the owned
# entity/device registries, the state snapshot and the registry changelog.
# It listens on localhost only and trusts loopback connections — nothing on
# the LAN can reach it and it holds no secrets. The production database
# lives on grafton-router (see hosts/grafton-router/services/postgres.nix);
# this module deliberately does not copy its TLS, scram or backup setup.
#
#   shell:  psql postgres://hass_rs@127.0.0.1/hass_rs
#   hass-rs: --database-url postgres://hass_rs@127.0.0.1/hass_rs
#   tests:  HASS_RS_PG_TEST_DSN=postgres://hass_rs@127.0.0.1/hass_rs \
#             cargo test -p hass-store -- --ignored
{ pkgs, ... }:
{
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_17;
    enableTCPIP = true;

    # listen_addresses stays at the default (localhost). Trust on loopback
    # only; pg_hba rejects everything else.
    authentication = pkgs.lib.mkOverride 10 ''
      #type   database  DBuser  address       auth-method
      local   all       all                   peer
      host    all       all     127.0.0.1/32  trust
      host    all       all     ::1/128       trust
    '';

    ensureDatabases = [ "hass_rs" ];
    ensureUsers = [
      {
        name = "hass_rs";
        ensureClauses.superuser = false;
        ensureClauses.createdb = false;
      }
    ];
  };

  # ensureDatabases creates the DB as the postgres superuser; PG 15+ also
  # stopped letting everyone write to `public`. Hand the schema to the
  # hass_rs role so hass-rs's own `migrate` can create its tables (idempotent).
  # On the very first switch the DB is only created in postgresql's postStart,
  # so retry until it answers.
  systemd.services.hass-rs-postgres-grant = {
    after = [ "postgresql.service" ];
    requires = [ "postgresql.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.postgresql_17 ];
    script = ''
      for _ in $(seq 1 12); do
        if psql --set=ON_ERROR_STOP=1 -q -d hass_rs <<'SQL'
      GRANT ALL ON SCHEMA public TO hass_rs;
      SQL
        then
          exit 0
        fi
        sleep 5
      done
      exit 1
    '';
    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  # psql for poking at the store by hand.
  environment.systemPackages = [ pkgs.postgresql_17 ];
}
