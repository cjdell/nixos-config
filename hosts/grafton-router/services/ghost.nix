{ config, ... }:

let
  GHOST_UID = 2368;

  CHRISDELL_BLOG_PORT = 2360;
  JACKSBALLARD_PORT = 2361;

  PLAUSIBLE_PORT = 9001;
  CLICKHOUSE_HTTP_PORT = 9002;
  CLICKHOUSE_TCP_PORT = 9003;
in
{
  users.users.ghost = {
    uid = GHOST_UID;
    group = "users";
    isNormalUser = true;
  };

  # journalctl -u podman-chrisdell -f
  virtualisation.oci-containers.containers = {
    chrisdell = {
      hostname = "chrisdell";
      image = "docker.io/ghost:alpine";
      autoStart = true;
      ports = [
        "${toString CHRISDELL_BLOG_PORT}:2368"
      ];
      volumes = [
        "/srv/chrisdell.info:/var/lib/ghost/content"
      ];
      environment = {
        TZ = "Europe/London";
        url = "https://chrisdell.info";
        database__client = "sqlite3";
        database__useNullAsDefault = "true";
        database__connection__filename = "/var/lib/ghost/content/data/ghost.db";
        mail__from = "noreply@chrisdell.info";
        security__staffDeviceVerification = "false";
      };
      extraOptions = [
        "--user=${toString GHOST_UID}:100"
      ];
    };
  };

  # journalctl -u podman-jacksballard -f
  virtualisation.oci-containers.containers = {
    jacksballard = {
      hostname = "jacksballard";
      image = "docker.io/ghost:alpine";
      autoStart = true;
      ports = [
        "${toString JACKSBALLARD_PORT}:2368"
      ];
      volumes = [
        "/srv/jacksballard.com:/var/lib/ghost/content"
      ];
      environment = {
        TZ = "Europe/London";
        url = "https://jacksballard.home.chrisdell.info";
        database__client = "sqlite3";
        database__useNullAsDefault = "true";
        database__connection__filename = "/var/lib/ghost/content/data/ghost.db";
        mail__from = "noreply@jacksballard.com";
        security__staffDeviceVerification = "false";
      };
      extraOptions = [
        "--user=${toString GHOST_UID}:100"
      ];
    };
  };

  # journalctl -u plausible -f
  services.plausible = {
    enable = true;
    server = {
      port = PLAUSIBLE_PORT;
      baseUrl = "https://analytics.home.chrisdell.info";
      # secretKeybaseFile is a path to the file which contains the secret generated
      # with openssl as described above.
      secretKeybaseFile = config.sops.secrets.plausible_secret_key.path;
    };
    database = {
      postgres.setup = true;
      clickhouse = {
        setup = false;
        url = "http://localhost:${toString CLICKHOUSE_HTTP_PORT}/default";
      };
    };
  };

  # Plausible needs Clickhouse, so wait for it
  systemd.services.plausible = {
    after = [ "clickhouse.service" ];
    requires = [ "clickhouse.service" ];
  };

  services.clickhouse = {
    enable = true;
    serverConfig = {
      http_port = CLICKHOUSE_HTTP_PORT;
      tcp_port = CLICKHOUSE_TCP_PORT;
    };

    # ClickHouse's `system.*_log` tables have NO TTL by default, so they grow
    # without bound. On 2026-11-01 that filled `/` (92 GiB of trace_log /
    # metric_log parts, oldest from Feb 2026 -> 2.05 billion trace rows):
    # zigbee2mqtt, plausible and dnsmasq lease writes all died with ENOSPC and
    # even podman could not create containers. Plausible (the only user of this
    # ClickHouse) never reads these tables, so keep a week (3 days for the
    # sampling profiler) and stop sampling stack traces altogether.
    extraServerConfig = ''
      <clickhouse>
        <!-- System log retention. Applied to the existing tables on start. -->
        <trace_log><ttl>event_time + INTERVAL 3 DAY</ttl></trace_log>
        <!-- No <ttl> here: opentelemetry_span_log has an <engine> in the stock
             config and ClickHouse rejects a separate ttl element for those. -->
        <query_log><ttl>event_time + INTERVAL 7 DAY</ttl></query_log>
        <query_thread_log><ttl>event_time + INTERVAL 7 DAY</ttl></query_thread_log>
        <query_views_log><ttl>event_time + INTERVAL 7 DAY</ttl></query_views_log>
        <query_metric_log><ttl>event_time + INTERVAL 7 DAY</ttl></query_metric_log>
        <part_log><ttl>event_time + INTERVAL 7 DAY</ttl></part_log>
        <metric_log><ttl>event_time + INTERVAL 7 DAY</ttl></metric_log>
        <asynchronous_metric_log><ttl>event_time + INTERVAL 7 DAY</ttl></asynchronous_metric_log>
        <asynchronous_insert_log><ttl>event_time + INTERVAL 7 DAY</ttl></asynchronous_insert_log>
        <processors_profile_log><ttl>event_time + INTERVAL 7 DAY</ttl></processors_profile_log>
        <text_log><ttl>event_time + INTERVAL 7 DAY</ttl></text_log>
        <error_log><ttl>event_time + INTERVAL 7 DAY</ttl></error_log>
        <session_log><ttl>event_time + INTERVAL 7 DAY</ttl></session_log>
      </clickhouse>
    '';

    # These are user-level settings (they live in users.xml profiles, not in
    # config.xml — putting them in extraServerConfig above makes the server die
    # at startup with UNKNOWN_ELEMENT_IN_CONFIG). 0s = no periodic stack
    # sampling, which is what generated 2 billion trace_log rows.
    usersConfig = {
      profiles.default = {
        query_profiler_real_time_period_ns = 0;
        query_profiler_cpu_time_period_ns = 0;
      };
    };
  };

  services.postgresqlBackup.databases = [ "plausible" ];

  system.activationScripts.ghost = ''
    # Create config and storage directories
    mkdir -p /srv/chrisdell.info
    mkdir -p /srv/jacksballard.com

    # Ensure correct permissions
    chown -R ${toString GHOST_UID}:users /srv/chrisdell.info
    chown -R ${toString GHOST_UID}:users /srv/jacksballard.com

    chmod -R g+rw /srv/chrisdell.info
    chmod -R g+rw /srv/jacksballard.com
  '';

  services.nginx.virtualHosts = {
    "chrisdell.info" = {
      useACMEHost = "chrisdell.info";
      forceSSL = true;

      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString CHRISDELL_BLOG_PORT}";
        recommendedProxySettings = true;
        proxyWebsockets = true;
      };
    };

    "jacksballard.home.chrisdell.info" = {
      useACMEHost = "chrisdell.info";
      forceSSL = true;

      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString JACKSBALLARD_PORT}";
        recommendedProxySettings = true;
        proxyWebsockets = true;
      };
    };

    "analytics.home.chrisdell.info" = {
      useACMEHost = "chrisdell.info";
      forceSSL = true;

      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString PLAUSIBLE_PORT}";
        recommendedProxySettings = true;
        proxyWebsockets = true;
      };
    };
  };
}
