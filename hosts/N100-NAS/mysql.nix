{
  pkgs,
  ...
}:

# Shared MariaDB server for this host (the unified services.mysql module in
# nixpkgs 26.11). Services that need a database add their own
# services.mysql.ensureDatabases / ensureUsers — plus an app user password if
# the app authenticates by password — in their own module; see
# christcentralpreston.nix for the reference use. Only loopback is served, so
# this is for co-located apps (containers with host networking included).
#
# The datadir gets its own dataset (mirroring the ds-postgres pattern). SQL
# dumps are the consumers' job and land on ds-db-backups, which syncoid pushes
# to N40L-NAS (see backup.nix) — never on ds-photos, which is for photos only.
{
  disko.zfs = {
    enable = true;
    settings.datasets = {
      "samsung-4tb/ds-mysql" = { };
    };
  };

  services.mysql = {
    enable = true;
    package = pkgs.mariadb;
    dataDir = "/samsung-4tb/ds-mysql/data";
    settings.mysqld = {
      bind-address = "127.0.0.1";
    };
  };
}
