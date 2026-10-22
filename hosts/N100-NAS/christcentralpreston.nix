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
# samsung-4tb/ds-christcentralpreston, mounted at the old ISPConfig path
# /var/www/clients/client0/web2 — verbatim on the host *and* inside the FPM
# container (bind mount), so the SCRIPT_FILENAME nginx passes to PHP-FPM
# resolves identically on both sides. The dataset joins the hourly syncoid
# run alongside ds-media (backup.nix). MariaDB's datadir gets its own
# dataset too (samsung-4tb/ds-mysql, mirroring the ds-postgres pattern); the
# database itself is additionally protected by a nightly dump on the
# syncoid'd ds-photos.
#
# TLS terminates on the grafton-router edge; this host serves plain HTTP on
# port 80. The vhost reports HTTPS to PHP when the edge sends
# X-Forwarded-Proto: https (see the $ccp_https map).
#
# Restore notes (2026-10-22, content imported out-of-band from
# backups/2026-10-21): the tar was unpacked into the dataset, chowned to
# web2:client0, the SQL dump imported, application/config/database.php
# switched to 'server' => '127.0.0.1' (the container reaches MariaDB over
# loopback), and concrete/bootstrap/configure.php's error_reporting() line
# extended with & ~E_WARNING — Concrete 8.3.2's vendor code trips the PHP
# >=7.3 "continue in switch" warning while the core resets error_reporting at
# runtime (pool php_admin_value can't win); upstream fixed this in 8.5.
# A backup of the original sits next to it as configure.php.orig-20261022.

let
  # Site owner, same numeric uid on the host and in the FPM pool config.
  uid = 970;
  user = "web2";
  group = "client0";
  docRoot = "/var/www/clients/client0/web2/web";

  db = "c0ccp";
  # Same credentials as production (from application/config/database.php in
  # the backup archive); the app connects to MariaDB on loopback, so the
  # restored database.php has 'server' => '127.0.0.1'.
  dbPassword = "eoN#oNAAh9";

  mysqlDataDir = "/samsung-4tb/ds-mysql/data";

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

  # --- website data (ZFS datasets) ------------------------------------------

  # Declarative datasets via disko-zfs (same pattern as the N40L/GEN8 NASes):
  #   samsung-4tb/ds-christcentralpreston -> /var/www/clients/client0/web2
  #   samsung-4tb/ds-mysql                -> /samsung-4tb/ds-mysql (datadir root)
  # The site dataset mounts at the literal ISPConfig path so host, container
  # and nginx all agree on it.
  disko.zfs = {
    enable = true;
    settings.datasets = {
      "samsung-4tb/ds-christcentralpreston" = {
        properties."mountpoint" = "/var/www/clients/client0/web2";
      };
      "samsung-4tb/ds-mysql" = { };
    };
  };

  # --- database -------------------------------------------------------------

  # MariaDB (the unified services.mysql module in nixpkgs 26.11).
  services.mysql = {
    enable = true;
    package = pkgs.mariadb;
    dataDir = mysqlDataDir;
    settings.mysqld = {
      # Only the co-located PHP-FPM container (host networking) talks to it.
      "bind-address" = "127.0.0.1";
    };
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

  # Nightly dump next to the photos dataset (syncoid'd to dbthr33); keep 14.
  systemd.services.christcentralpreston-db-dump = {
    description = "christcentralpreston.co.uk: mysqldump c0ccp";
    path = [ pkgs.mariadb ];
    serviceConfig.type = "oneshot";
    script = ''
      mkdir -p /samsung-4tb/ds-photos/christcentralpreston-db
      dump=${db}-$(date +%F).sql.gz
      mysqldump --socket=/run/mysqld/mysqld.sock --single-transaction --routines --triggers --events ${db} | \
        gzip -9 > /samsung-4tb/ds-photos/christcentralpreston-db/$dump.tmp
      mv /samsung-4tb/ds-photos/christcentralpreston-db/$dump.tmp \
        /samsung-4tb/ds-photos/christcentralpreston-db/$dump
      find /samsung-4tb/ds-photos/christcentralpreston-db -name '*.sql.gz' -mtime +14 -delete
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
      type = "oneshot";
      remainAfterExit = true;
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
      "/var/www/clients/client0/web2:/var/www/clients/client0/web2:rw"
      "${fpmPool}:/usr/local/etc/php-fpm.d/www.conf:ro"
    ];
  };

  systemd.services."podman-christcentralpreston-php".unitConfig.RequiresMountsFor =
    "/var/www/clients/client0/web2";

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
