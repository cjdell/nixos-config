{
  config,
  pkgs,
  lib,
  ...
}:
# Alert rules for backup jobs and system health
{
  services.prometheus = {
    enable = true;
    port = 9090;

    rules = [
      (builtins.toJSON {
        groups = [
          {
            name = "backups";
            interval = "1m";
            rules = [
              {
                alert = "BackupJobFailed";
                expr = "node_systemd_unit_state{name=~\".*syncoid.*\\\\.service\", state=\"failed\"} == 1";
                for = "5m";
                labels.severity = "critical";
                annotations.summary = "Backup job failed on {{ $labels.instance }}";
                annotations.description = "Service {{ $labels.name }} is in failed state";
              }
            ];
          }
          {
            name = "zfs";
            interval = "1m";
            rules = [
              {
                alert = "ZFSPoolDegraded";
                expr = "zfs_pool_health{state!=\"online\"} > 0";
                for = "5m";
                labels.severity = "critical";
                annotations.summary = "ZFS pool {{ $labels.name }} is degraded on {{ $labels.instance }}";
                annotations.description = "Pool state is {{ $labels.state }}";
              }
              {
                alert = "ZFSPoolLowSpace";
                expr = "(zfs_pool_free_bytes / zfs_pool_size_bytes) * 100 < 10";
                for = "10m";
                labels.severity = "warning";
                annotations.summary = "ZFS pool {{ $labels.name }} low on space on {{ $labels.instance }}";
                annotations.description = "Only {{ $value | humanize }}% free space remaining";
              }
              {
                alert = "ZFSPoolCriticalSpace";
                expr = "(zfs_pool_free_bytes / zfs_pool_size_bytes) * 100 < 5";
                for = "5m";
                labels.severity = "critical";
                annotations.summary = "ZFS pool {{ $labels.name }} critically low on space on {{ $labels.instance }}";
                annotations.description = "Only {{ $value | humanize }}% free space remaining";
              }
              {
                alert = "ZFSScrubErrors";
                expr = "increase(zfs_pool_scrub_errors_total[24h]) > 0";
                for = "5m";
                labels.severity = "critical";
                annotations.summary = "ZFS scrub found errors on pool {{ $labels.name }} on {{ $labels.instance }}";
                annotations.description = "Scrub detected {{ $value }} errors in the last 24 hours";
              }
            ];
          }
          {
            name = "smart";
            interval = "2m";
            rules = [
              {
                alert = "SMARTDeviceUnhealthy";
                expr = "smartctl_device_smart_healthy == 0";
                for = "5m";
                labels.severity = "critical";
                annotations.summary = "SMART reports {{ $labels.device }} unhealthy on {{ $labels.instance }}";
                annotations.description = "Drive {{ $labels.device }} is failing SMART health checks";
              }
              {
                alert = "SMARTHighTemperature";
                expr = "smartctl_device_temperature > 60";
                for = "15m";
                labels.severity = "warning";
                annotations.summary = "High temperature on {{ $labels.device }} on {{ $labels.instance }}";
                annotations.description = "Drive temperature is {{ $value }}°C";
              }
              {
                alert = "SMARTReallocatedSectors";
                expr = "smartctl_device_attribute_value{attribute_name=\"Reallocated_Sector_Ct\"} > 0";
                for = "5m";
                labels.severity = "warning";
                annotations.summary = "Reallocated sectors detected on {{ $labels.device }} on {{ $labels.instance }}";
                annotations.description = "{{ $value }} reallocated sectors detected";
              }
              {
                alert = "SMARTPendingSectors";
                expr = "smartctl_device_attribute_value{attribute_name=\"Current_Pending_Sector\"} > 0";
                for = "5m";
                labels.severity = "warning";
                annotations.summary = "Pending sectors on {{ $labels.device }} on {{ $labels.instance }}";
                annotations.description = "{{ $value }} pending sectors detected";
              }
              {
                alert = "SMARTUncorrectableErrors";
                expr = "smartctl_device_attribute_value{attribute_name=\"Offline_Uncorrectable\"} > 0";
                for = "5m";
                labels.severity = "critical";
                annotations.summary = "Uncorrectable errors on {{ $labels.device }} on {{ $labels.instance }}";
                annotations.description = "{{ $value }} uncorrectable errors detected";
              }
              {
                alert = "SMARTHighErrorRate";
                expr = "rate(smartctl_device_attribute_value{attribute_name=~\".*Error.*\"}[1h]) > 0";
                for = "10m";
                labels.severity = "warning";
                annotations.summary = "Increasing error rate on {{ $labels.device }} on {{ $labels.instance }}";
              }
            ];
          }
          {
            name = "system_health";
            interval = "30s";
            rules = [
              {
                alert = "HighCPU";
                expr = "100 - (avg by (instance) (irate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100) > 80";
                for = "10m";
                labels.severity = "warning";
                annotations.summary = "High CPU usage on {{ $labels.instance }}";
              }
              {
                alert = "HighMemory";
                expr = "(node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 < 10";
                for = "5m";
                labels.severity = "warning";
                annotations.summary = "Low memory on {{ $labels.instance }}";
              }
              {
                alert = "DiskSpaceLow";
                expr = "(node_filesystem_avail_bytes{fstype!~\"tmpfs|fuse.*\"} / node_filesystem_size_bytes) * 100 < 10";
                for = "5m";
                labels.severity = "critical";
                annotations.summary = "Disk space low on {{ $labels.instance }}";
              }
              {
                alert = "ServiceDown";
                expr = "up == 0";
                for = "2m";
                labels.severity = "critical";
                annotations.summary = "{{ $labels.instance }} is down";
              }
            ];
          }
        ];
      })
    ];

    # Scrape configs - tell Prometheus where to collect metrics
    scrapeConfigs = [
      {
        job_name = "node";
        static_configs = [
          {
            targets = [
              "n100-nas.grafton.lan:9100" # monitoring server itself
              "gen8-nas.grafton.lan:9100"
            ];
          }
        ];
        relabel_configs = [
          {
            source_labels = [ "__address__" ];
            regex = "([^:]+):.*";
            target_label = "instance";
            replacement = "$1";
          }
        ];
      }
      {
        job_name = "systemd";
        static_configs = [
          {
            targets = [
              "n100-nas.grafton.lan:9558"
              "gen8-nas.grafton.lan:9558"
            ];
          }
        ];
        relabel_configs = [
          {
            source_labels = [ "__address__" ];
            regex = "([^:]+):.*";
            target_label = "instance";
            replacement = "$1";
          }
        ];
      }
      {
        job_name = "zfs";
        static_configs = [
          {
            targets = [
              "n100-nas.grafton.lan:9134"
              "gen8-nas.grafton.lan:9134"
            ];
          }
        ];
        relabel_configs = [
          {
            source_labels = [ "__address__" ];
            regex = "([^:]+):.*";
            target_label = "instance";
            replacement = "$1";
          }
        ];
      }
      # New SMART scrape config
      {
        job_name = "smartctl";
        static_configs = [
          {
            targets = [
              "n100-nas.grafton.lan:9633"
              "gen8-nas.grafton.lan:9633"
            ];
          }
        ];
        # SMART checks are slow, scrape less frequently
        scrape_interval = "120s";
        relabel_configs = [
          {
            source_labels = [ "__address__" ];
            regex = "([^:]+):.*";
            target_label = "instance";
            replacement = "$1";
          }
        ];
      }
    ];

    alertmanagers = [
      {
        static_configs = [
          {
            targets = [ "localhost:9093" ];
          }
        ];
      }
    ];
  };

  # Alertmanager sends notifications
  services.prometheus.alertmanager = {
    enable = true;
    port = 9093;
    configuration = {
      global = {
        resolve_timeout = "5m";
      };
      route = {
        group_by = [
          "alertname"
          "instance"
        ];
        group_wait = "30s";
        group_interval = "5m";
        repeat_interval = "12h";
        receiver = "webhook";
      };
      receivers = [
        {
          name = "webhook";
          webhook_configs = [
            {
              url = "http://localhost:9095/alert"; # Your webhook receiver
              send_resolved = true;
            }
          ];
        }
      ];
    };
  };

  # Grafana for visualization
  services.grafana = {
    enable = true;
    settings = {
      server = {
        http_addr = "0.0.0.0";
        http_port = 3000;
        root_url = "https://grafana.home.chrisdell.info";
      };
      # security = {
      #   admin_user = "admin";
      #   admin_password = "????";
      # };
      "auth.generic_oauth" = {
        enabled = "true";
        name = "Kanidm";
        client_id = "grafana";
        client_secret = "$__file{${config.sops.secrets.grafana_oidc_client_secret.path}}";
        scopes = "openid,profile,email,groups";
        auth_url = "https://kanidm.home.chrisdell.info/ui/oauth2";
        token_url = "https://kanidm.home.chrisdell.info/oauth2/token";
        api_url = "https://kanidm.home.chrisdell.info/oauth2/openid/grafana/userinfo";
        use_pkce = "true";
        use_refresh_token = "true";
        allow_sign_up = "true";
        login_attribute_path = "preferred_username";
        groups_attribute_path = "groups";
        role_attribute_path = "contains(grafana_role[*], 'GrafanaAdmin') && 'GrafanaAdmin' || contains(grafana_role[*], 'Admin') && 'Admin' || contains(grafana_role[*], 'Editor') && 'Editor' || 'Viewer'";
        allow_assign_grafana_admin = "true";
      };
    };
    provision = {
      enable = true;
      datasources.settings.datasources = [
        {
          name = "Prometheus";
          type = "prometheus";
          url = "http://localhost:9090";
          isDefault = true;
        }
      ];
    };
  };

  # Exporters on the monitoring server itself
  services.prometheus.exporters = {
    node = {
      enable = true;
      port = 9100;
      enabledCollectors = [ "systemd" ];
    };

    systemd = {
      enable = true;
      port = 9558;
    };

    # ZFS exporter
    zfs = {
      enable = true;
      port = 9134;
    };

    # SMART exporter
    smartctl = {
      enable = true;
      port = 9633;
      # Specify which devices to monitor (optional, auto-detects if not set)
      # devices = [ "/dev/sda" "/dev/sdb" "/dev/nvme0n1" ];
    };
  };

  # Add to monitoring server config
  # journalctl -u alert-webhook -f
  systemd.services.alert-webhook = {
    description = "Alert Webhook to Curl";
    wantedBy = [ "multi-user.target" ];
    script = ''
      ${pkgs.python3}/bin/python3 ${pkgs.writeText "webhook.py" ''
        from http.server import HTTPServer, BaseHTTPRequestHandler
        import json
        import subprocess

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers['Content-Length'])
                data = json.loads(self.rfile.read(length))

                for alert in data.get('alerts', []):
                    status = alert.get('status')
                    labels = alert.get('labels', {})
                    annotations = alert.get('annotations', {})

                    message = f"{status.upper()}: {annotations.get('summary', 'Alert')}"

                    # Your curl command here - customize as needed
                    subprocess.run([
                        '${lib.getExe pkgs.curl}', '-X', 'POST',
                        'https://notify.home.chrisdell.info',
                        '-H', 'Content-Type: application/json',
                        '-d', json.dumps({'title':'Prometheus','message':message})
                    ])

                self.send_response(200)
                self.end_headers()

            def log_message(self, format, *args):
                pass

        HTTPServer(('0.0.0.0', 9095), Handler).serve_forever()
      ''}
    '';
  };
}
