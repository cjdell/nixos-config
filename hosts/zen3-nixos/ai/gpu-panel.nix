{
  config,
  lib,
  pkgs,
  ...
}:

# gpu-panel: native GPU telemetry + overdrive control web UI for the R9700.
#
# Telemetry (temps, fan, power, clocks, utilisation, VRAM) is read straight
# from sysfs by the Rust service; control writes (fan curve / power cap /
# clocks / voltage / performance level) are sent to the LACT daemon over its
# unix socket, which owns the SMU plumbing and the unconfirmed-change
# auto-revert timer.
#
# The PID thermal loop is different: when armed it takes the fan away from
# LACT and writes the SMU overdrive fan curve directly (gpu_od/fan_ctrl),
# updating every `interval_ms`. It releases control back to the firmware on
# stop or shutdown.
#
# nginx: owns the /gpu locations on the IP vhost plus the public
# gpu.ai.chrisdell.info subdomain. The panel is unauthenticated, like the
# other AI service endpoints on this host.

let
  gpu-panel = pkgs.rustPlatform.buildRustPackage {
    pname = "gpu-panel";
    version = "0.1.0";
    src = ../../../gpu-panel;
    cargoLock.lockFile = ../../../gpu-panel/Cargo.lock;
    doCheck = false;
  };

  # SSE stream (/api/stream) must not be buffered by nginx, and the panel is
  # long-lived by design.
  proxyExtra = ''
    proxy_buffering off;
    proxy_cache off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
  '';

  # IP vhost: /gpu/ prefix stripped before proxying (the UI uses relative
  # URLs, so it works identically under /gpu/ and the subdomain root).
  gpuLocation = {
    proxyPass = "http://127.0.0.1:8087";
    recommendedProxySettings = true;
    extraConfig = ''
      rewrite ^/gpu/?(.*)$ /$1 break;
      ${proxyExtra}
    '';
  };
in
{
  systemd.tmpfiles.rules = [
    # Persisted PID controller settings (armed state, target, gains).
    "d /var/lib/gpu-panel 0755 root root - -"
  ];

  systemd.services.gpu-panel = {
    description = "GPU panel - telemetry + overdrive control web UI (R9700)";
    after = [ "lact.service" "network.target" ];
    wants = [ "lact.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      ExecStart = "${gpu-panel}/bin/gpu-panel --listen 127.0.0.1:8087 --pci 0000:03:00.0 --state /var/lib/gpu-panel/thermal.json";
      Restart = "always";
      RestartSec = 5;
      # Runs as root: sysfs gpu_od fan-curve writes and the LACT socket
      # (root:wheel, 0660) both need it.
      TimeoutStopSec = 20;
    };
  };

  services.nginx.virtualHosts = {
    # ---- IP vhost (192.168.49.50) ----

    "192.168.49.50".locations = {
      "= /gpu" = {
        return = "301 /gpu/";
      };

      "/gpu/" = gpuLocation;
    };

    # ---- Public subdomain (unauthenticated, same as the other AI services;
    # the wildcard vhost also serves /gpu/ since it reuses the IP vhost
    # locations). ----

    "gpu.ai.chrisdell.info" = {
      useACMEHost = "ai.chrisdell.info";
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:8087";
        recommendedProxySettings = true;
        extraConfig = proxyExtra;
      };
    };
  };
}
