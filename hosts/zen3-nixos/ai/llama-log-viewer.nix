{ lib, pkgs, ... }:

# Zero-dependency Rust web app that browses llama-server's
# --log-prompts-dir output (see llama-log-viewer/README.md).
#
# nginx: owns the /logs locations on the IP vhost plus the public
# logs.ai.chrisdell.info subdomain (whole app at the root, no /logs prefix).

let
  llama-log-viewer = pkgs.rustPlatform.buildRustPackage {
    pname = "llama-log-viewer";
    version = "0.1.0";
    src = ../../../llama-log-viewer;
    cargoLock.lockFile = ../../../llama-log-viewer/Cargo.lock;
    doCheck = false;
  };
in
{
  systemd.services.llama-log-viewer = {
    description = "Llama Log Viewer";
    after = [ "wait-for-network.service" ];
    wants = [ "wait-for-network.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      ExecStart = "${llama-log-viewer}/bin/llama-log-viewer --logs /home/cjdell/nixos-config/llama-logs --host 127.0.0.1 --port 8083";
      Restart = "always";
      RestartSec = 5;
    };
  };

  services.nginx.virtualHosts = {
    # ---- IP vhost (192.168.49.50): /logs with the prefix stripped. ----

    "192.168.49.50".locations = {
      # Redirect bare /logs to /logs/ so relative URLs resolve inside the app
      "= /logs" = {
        return = "301 /logs/";
      };

      "/logs" = {
        # Strip the /logs prefix explicitly, then proxy without a URI so
        # nginx forwards the rewritten path (e.g. /logs/api/stats -> /api/stats)
        proxyPass = "http://127.0.0.1:8083";
        extraConfig = ''
          rewrite ^/logs/?(.*)$ /$1 break;
        '';
        recommendedProxySettings = true;
        proxyWebsockets = true;
      };
    };

    # ---- Public subdomain ----

    "logs.ai.chrisdell.info" = {
      useACMEHost = "ai.chrisdell.info";
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:8083";
        recommendedProxySettings = true;
        proxyWebsockets = true;
      };
    };
  };
}
