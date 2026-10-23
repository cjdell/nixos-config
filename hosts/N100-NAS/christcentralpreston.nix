{
  config,
  pkgs,
  ...
}:

# christcentralpreston.co.uk — Concrete CMS 8.3.2 restored 2026-10-22 from the
# 2026-10-21 backup of web.chrisdell.info (see the hetzner-web-backup project).
#
# Concrete 8.3.x needs the PHP 7 series (the old server ran PHP 7.4-FPM) and
# the pinned nixpkgs only has php82+, so the FPM runtime is a podman container
# built from `christcentralpreston/Dockerfile` (official php:7.4-fpm + gd,
# intl, zip, pdo_mysql, mysqli, exif).
#
# The website data lives in its own ZFS dataset,
# samsung-4tb/ds-christcentralpreston, mounted at /var/www/christcentralpreston
# — verbatim on the host *and* inside the FPM container (bind mount), so the
# SCRIPT_FILENAME nginx passes to PHP-FPM resolves identically on both sides.
# The legacy ISPConfig path (/var/www/clients/client0/web2) and account names
# (web2:client0) were retired 2026-10-23; uid/gid 970 are unchanged, so the
# restored tree needed no re-chown.
#
# MariaDB is a shared host service with its own datadir dataset — see
# mysql.nix; this file only declares the site's database/user. The database is
# additionally protected by a nightly dump on the ds-db-backups dataset,
# which syncoid pushes to N40L-NAS (see backup.nix).
#
# TLS terminates on the grafton-router edge; this host serves plain HTTP on
# port 80. The vhost reports HTTPS to PHP when the edge sends
# X-Forwarded-Proto: https (see the $ccp_https map).
#
# Restore notes (2026-10-22, content imported out-of-band from
# backups/2026-10-21): the tar was unpacked into the dataset, chowned to the
# site owner (numeric 970:970), the SQL dump imported,
# application/config/database.php switched to 'server' => '127.0.0.1' (the
# container reaches MariaDB over loopback), and concrete/bootstrap/configure.php's
# error_reporting() line extended with & ~E_WARNING — Concrete 8.3.2's vendor
# code trips the PHP >=7.3 "continue in switch" warning while the core resets
# error_reporting at runtime (pool php_admin_value can't win); upstream fixed
# this in 8.5. A backup of the original sits next to it as
# configure.php.orig-20261022.

let
  # Site owner (user and group), same numeric uid on the host and in the FPM
  # pool config; 970 is what the restored tree is owned by.
  uid = 970;
  user = "christcentralpreston";
  group = "christcentralpreston";
  siteRoot = "/var/www/christcentralpreston";
  docRoot = "${siteRoot}/web";

  db = "c0ccp";
  # Same credentials as production (from application/config/database.php in
  # the backup archive); the app connects to MariaDB on loopback, so the
  # restored database.php has 'server' => '127.0.0.1'.
  dbPassword = "eoN#oNAAh9";

  # SQL dumps ride along on the dataset syncoid'd to N40L-NAS (backup.nix).
  dumpDir = "/samsung-4tb/ds-db-backups/christcentralpreston";

  fpmPort = 9000;
  phpImage = "localhost/christcentralpreston-php74:1";
  phpRuntimeDir = ./christcentralpreston;

  # Replaces the image's /usr/local/etc/php-fpm.d/www.conf: workers run as the
  # site owner (numeric uid, the container has no passwd entry), listen on
  # loopback only, and match the old PHP 7.4-FPM limits.
  #
  # error_reporting = 32765 is E_ALL & ~E_WARNING: Concrete 8.3.x predates the
  # PHP 7.3 "continue in switch" warning and its error handler promotes any
  # reported E_WARNING to an exception; the old ISPConfig pool ran with
  # warnings suppressed, so keep parity.
  fpmPool = pkgs.writeText "christcentralpreston-php-fpm.conf" ''
    [www]
    user = ${toString uid}
    group = ${toString uid}
    listen = 127.0.0.1:${toString fpmPort}
    pm = ondemand
    pm.max_children = 10
    pm.process_idle_timeout = 30s
    catch_workers_output = yes
    php_admin_value[error_reporting] = 32765
    php_admin_value[display_errors] = Off
    php_admin_value[upload_max_filesize] = 64M
    php_admin_value[post_max_size] = 64M
    php_admin_value[memory_limit] = 512M
    php_admin_value[max_execution_time] = 300
    php_admin_value[date.timezone] = Europe/London
    php_admin_value[session.save_path] = /tmp
    php_admin_value[upload_tmp_dir] = /tmp
  '';

  # nginx ships fastcgi_params outside its confdir in nixpkgs, so keep our own.
  fastcgiParams = pkgs.writeText "christcentralpreston-fastcgi-params" ''
    fastcgi_param  QUERY_STRING       $query_string;
    fastcgi_param  REQUEST_METHOD     $request_method;
    fastcgi_param  CONTENT_TYPE       $content_type;
    fastcgi_param  CONTENT_LENGTH     $content_length;

    fastcgi_param  SCRIPT_NAME        $fastcgi_script_name;
    fastcgi_param  REQUEST_URI        $request_uri;
    fastcgi_param  DOCUMENT_URI       $document_uri;
    fastcgi_param  DOCUMENT_ROOT      $document_root;
    fastcgi_param  SCRIPT_FILENAME    $document_root$fastcgi_script_name;
    fastcgi_param  SERVER_PROTOCOL    $server_protocol;
    fastcgi_param  REQUEST_SCHEME     $scheme;
    fastcgi_param  HTTPS              $ccp_https if_not_empty;

    fastcgi_param  GATEWAY_INTERFACE  CGI/1.1;
    fastcgi_param  SERVER_SOFTWARE    nginx;

    fastcgi_param  REMOTE_ADDR        $remote_addr;
    fastcgi_param  REMOTE_PORT        $remote_port;
    fastcgi_param  REMOTE_USER        $remote_user;
    fastcgi_param  SERVER_ADDR        $server_addr;
    fastcgi_param  SERVER_PORT        $server_port;
    fastcgi_param  SERVER_NAME        $server_name;
  '';
in
{
  users.groups.${group}.gid = uid;
  users.users.${user} = {
    isSystemUser = true;
    inherit uid;
    group = group;
  };

  # --- website data (ZFS dataset) --------------------------------------------

  # Declarative dataset via disko-zfs (same pattern as the N40L/GEN8 NASes):
  #   samsung-4tb/ds-christcentralpreston -> /var/www/christcentralpreston
  # The dataset mounts at the site root so host, container and nginx all agree
  # on it; zfs set mountpoint (applied by disko-zfs at activation) moves it off
  # the old ISPConfig path. The MySQL datadir dataset lives in mysql.nix and
  # the dump dataset in backup.nix.
  disko.zfs = {
    enable = true;
    settings.datasets."samsung-4tb/ds-christcentralpreston" = {
      properties."mountpoint" = siteRoot;
    };
  };

  # --- database -------------------------------------------------------------

  # MariaDB itself is the shared host service (mysql.nix); this site only
  # declares its database and user.
  services.mysql = {
    ensureDatabases = [ db ];
    ensureUsers = [
      {
        name = db;
        ensurePermissions = {
          "${db}.*" = "ALL PRIVILEGES";
        };
      }
    ];
  };

  # ensureUsers creates the account with unix_socket auth and no password;
  # Concrete needs the one from the restored application/config/database.php.
  systemd.services.christcentralpreston-db-init = {
    description = "christcentralpreston.co.uk: set c0ccp database password";
    after = [ "mysql.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.mariadb ];
    serviceConfig.type = "oneshot";
    script = "mysql --socket=/run/mysqld/mysqld.sock -e \"ALTER USER IF EXISTS '${db}'@'localhost' IDENTIFIED BY '${dbPassword}'; FLUSH PRIVILEGES;\"";
  };

  # Nightly dump on ds-db-backups (syncoid'd to N40L-NAS, see backup.nix);
  # keep 14. Note: gzip must be in `path` explicitly (the unit PATH is
  # minimal), and serviceConfig keys are case-sensitive — `type` (lowercase)
  # was silently dropped by systemd until 2026-10-23.
  systemd.services.christcentralpreston-db-dump = {
    description = "christcentralpreston.co.uk: mysqldump c0ccp";
    path = [
      pkgs.mariadb
      pkgs.gzip
    ];
    unitConfig.RequiresMountsFor = "/samsung-4tb/ds-db-backups";
    serviceConfig.Type = "oneshot";
    script = ''
      mkdir -p ${dumpDir}
      dump=${db}-$(date +%F).sql.gz
      mysqldump --socket=/run/mysqld/mysqld.sock --single-transaction --routines --triggers --events ${db} | \
        gzip -9 > ${dumpDir}/$dump.tmp
      mv ${dumpDir}/$dump.tmp ${dumpDir}/$dump
      find ${dumpDir} -name '*.sql.gz' -mtime +14 -delete
    '';
  };
  systemd.timers.christcentralpreston-db-dump = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 02:10:00";
      Persistent = true;
    };
  };

  # --- PHP-FPM 7.4 container -------------------------------------------------

  # Build the FPM image on first boot (idempotent; the podman layer cache
  # makes rebuilds after a switch a no-op while the tag is unchanged).
  systemd.services.christcentralpreston-php-image = {
    description = "christcentralpreston.co.uk: build PHP 7.4-FPM image";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    before = [ "podman-christcentralpreston-php.service" ];
    path = [ config.virtualisation.podman.package ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      if ! podman image exists "${phpImage}"; then
        podman build -t "${phpImage}" ${phpRuntimeDir}
      fi
    '';
  };

  virtualisation.oci-containers.containers."christcentralpreston-php" = {
    image = phpImage;
    pull = "never";
    autoStart = true;
    # Host networking so the app's `localhost` reaches the MariaDB on
    # 127.0.0.1 and nginx can fastcgi_pass to the loopback port below; the
    # pool binds loopback only, so nothing is exposed to the LAN.
    networks = [ "host" ];
    volumes = [
      "${siteRoot}:${siteRoot}:rw"
      "${fpmPool}:/usr/local/etc/php-fpm.d/www.conf:ro"
    ];
  };

  systemd.services."podman-christcentralpreston-php".unitConfig.RequiresMountsFor = siteRoot;

  # --- nginx (HTTP only; TLS lives on the grafton-router edge) ---------------

  services.nginx = {
    enable = true;

    # Declared before the vhosts so the fastcgi HTTPS param can reference it:
    # report HTTPS to PHP only when the edge sent X-Forwarded-Proto: https.
    commonHttpConfig = ''
      map $http_x_forwarded_proto $ccp_https {
        https on;
        default  "";
      }
    '';

    virtualHosts."christcentralpreston.co.uk" = {
      default = true;
      serverAliases = [ "www.christcentralpreston.co.uk" ];
      root = docRoot;

      extraConfig = ''
        client_max_body_size 64m;

        # The old .htaccess 301'd the bare domain to www.
        if ($host = "christcentralpreston.co.uk") {
          return 301 https://www.christcentralpreston.co.uk$request_uri;
        }
      '';

      # Legacy aliases from the old .htaccess.
      locations."= /about.html".extraConfig = "return 301 /about;";
      locations."= /contact.html".extraConfig = "return 301 /contact;";

      locations."/" = {
        # ConcreteCMS pretty URLs (the .htaccess rewrote to index.php unless
        # the file, file/index.html or file/index.php existed). Directory
        # indexes are off on the old box too (docroot is 711), so resolve
        # index.html then index.php like Apache's DirectoryIndex.
        extraConfig = ''
          index index.html index.php;
          try_files $uri $uri/ /index.php?$args;
        '';
      };

      locations."~ \.php$" = {
        extraConfig = ''
          include ${fastcgiParams};
          fastcgi_pass 127.0.0.1:${toString fpmPort};
          fastcgi_read_timeout 300s;
        '';
      };
    };
  };

  # Nginx must not race the FPM container on boot. unitConfig.After is merged
  # additively, unlike the `after` list option which would replace the
  # generated ordering.
  systemd.services.nginx.unitConfig.After = [ "podman-christcentralpreston-php.service" ];
}
