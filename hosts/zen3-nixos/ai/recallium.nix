{
  config,
  lib,
  pkgs,
  ...
}:

# Recallium: memory server for AI agents (MCP + web UI + Postgres), rootful
# podman container. LLM processing runs on the local llama.cpp via the
# /recallium-llm nginx proxy (GPU in config.ai.recalliumGpu). See
# docs/recallium.md.
#
# nginx: owns the Recallium locations on the IP vhost (/recallium,
# /recallium-llm, /api/ catch-all, /recallium-mcp with CORS) plus the public
# recallium.ai.chrisdell.info (UI + REST at the root, no sub_filter needed)
# and recallium-mcp.ai.chrisdell.info subdomains.

let
  # The Recallium UI is an Express app that redirects its root to a *relative*
  # /ui path. Under the IP vhost's /recallium/ prefix those relative Locations
  # must be rewritten back under the prefix, and the app's HTML/JS emit
  # *absolute* /ui/... references (asset tags, chunk URLs, images, the router
  # basename) that proxy_redirect does NOT touch (headers only) — hence the
  # sub_filter body rewrites. On recallium.ai.chrisdell.info none of this is
  # needed: the app runs at the root where /ui/... resolves natively.
  recalliumUiLocation = {
    proxyPass = "http://127.0.0.1:9001";
    extraConfig = ''
      rewrite ^/recallium/?(.*)$ /$1 break;
      # Rewrite relative /ui Locations back under the /recallium prefix,
      # otherwise the browser follows the first hop to /ui and lands on
      # llama-swap (nginx's "/" location).
      proxy_redirect / /recallium/;
      # Rewrite absolute /ui/... references in the response body back under
      # /recallium, else the browser requests /ui/... and hits llama-swap's
      # UI instead.
      sub_filter_once off;
      sub_filter_types text/html text/css application/javascript;
      sub_filter /ui/ /recallium/ui/;
      sub_filter '"/ui"' '"/recallium/ui"';
      # LLM-backed UI requests can take minutes.
      proxy_read_timeout 600s;
      proxy_send_timeout 600s;
    '';
    recommendedProxySettings = true;
    proxyWebsockets = true;
  };

  # CORS for the MCP endpoint is handled by nginx, not the app: answer
  # OPTIONS preflights locally (the app 400s preflights from origins outside
  # its fixed CORS_ORIGINS) and stamp CORS headers on every response, echoing
  # the request origin so credentialed requests work too. The upstream's own
  # CORS headers are hidden to avoid duplicates. Shared by the IP vhost's
  # /recallium-mcp and the recallium-mcp.ai.chrisdell.info root.
  recalliumMcpLocation = {
    proxyPass = "http://127.0.0.1:8001/mcp";
    recommendedProxySettings = true;
    proxyWebsockets = true;
    extraConfig = ''
      proxy_hide_header Access-Control-Allow-Origin;
      proxy_hide_header Access-Control-Allow-Credentials;
      proxy_hide_header Access-Control-Allow-Methods;
      proxy_hide_header Access-Control-Allow-Headers;
      proxy_hide_header Access-Control-Expose-Headers;
      proxy_hide_header Access-Control-Max-Age;

      add_header Access-Control-Allow-Origin $cors_origin always;
      add_header Access-Control-Allow-Credentials true always;
      add_header Access-Control-Allow-Methods "GET, POST, OPTIONS, DELETE" always;
      add_header Access-Control-Allow-Headers $cors_request_headers always;
      add_header Access-Control-Expose-Headers "mcp-session-id" always;
      add_header Access-Control-Max-Age 600 always;

      if ($request_method = OPTIONS) {
        return 204;
      }

      # MCP tool calls run the local LLM; memory ops can exceed the 60s
      # default, and Streamable HTTP responses are SSE and must not be
      # buffered (else clients wait on the first event).
      proxy_read_timeout 600s;
      proxy_send_timeout 600s;
      proxy_buffering off;
    '';
  };
in
{
  # Self-heal the Recallium MCP endpoint. The app's MCP server intermittently
  # stops responding to /mcp (upstream bug, no fixed image yet), which clients
  # see as a "context server request timeout". POST an `initialize`; if two
  # consecutive checks fail, restart the container (volumes persist).
  systemd.services.recallium-healthcheck = {
    description = "Restart Recallium container if its MCP endpoint stops responding";
    serviceConfig = {
      Type = "oneshot";
    };
    path = [ pkgs.curl ];
    script = ''
      mcp_code() {
        curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
          -X POST http://127.0.0.1:8001/mcp \
          -H 'Content-Type: application/json' -H 'Accept: application/json' \
          -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"healthcheck","version":"1"}}}'
      }
      first=$(mcp_code)
      if [ "$first" != "200" ]; then
        sleep 10
        second=$(mcp_code)
        if [ "$second" != "200" ]; then
          echo "Recallium MCP endpoint unhealthy (HTTP ''${first}, then ''${second}); restarting container"
          podman restart recallium
        fi
      fi
    '';
  };

  systemd.timers.recallium-healthcheck = {
    description = "Periodic Recallium MCP health check";
    timerConfig = {
      OnBootSec = "5m";
      OnUnitActiveSec = "2m";
      Unit = "recallium-healthcheck.service";
    };
    wantedBy = [ "timers.target" ];
  };

  virtualisation.oci-containers.containers.recallium = {
    hostname = "recallium";
    image = "recalliumai/recallium:latest";
    autoStart = true;
    ports = [
      "8001:8000" # MCP API
      "9001:9000" # Web UI
      "5433:5432" # PostgreSQL
    ];
    volumes = [
      "/var/lib/recallium/data:/data"
      "/var/lib/recallium/wal:/wal"
      "/var/lib/recallium/documents:/documents"
      "/var/lib/recallium/secrets:/secrets"
    ];
    extraOptions = [
      # Rootful podman: resolve host.containers.internal / host.docker.internal
      # to the host so OLLAMA_BASE_URL reaches the ollama-bridge on 11434.
      "--add-host=host.containers.internal:host-gateway"
      "--add-host=host.docker.internal:host-gateway"
    ];
    environment = {
      OLLAMA_BASE_URL = "http://host.containers.internal:11434";
      OLLAMA_HOST = "http://host.containers.internal:11434";
      UI_BASE_URL = "http://192.168.49.50:9001";
      TZ = "UTC";
      LOG_LEVEL = "INFO";
      WORKERS = "2";
      RECALLIUM_EDITION = "community";
      ENVIRONMENT = "production";
      LOAD_SAMPLE_DATA = "false";
      DB_HOST = "localhost";
      DB_PORT = "5432";
      DB_USER = "recallium";
      DB_PASSWORD = "recallium_password";
      DB_NAME = "recallium_memories";
      VAULT_PATH = "/secrets";
      # Vault passphrase: change this if you care about the vault contents
      # (it encrypts provider API keys; with the local Ollama provider there
      # are none). Generate a new one with `head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'`.
      VAULT_PASSPHRASE = "98ea4892878998a3badd3177a9d4ca61e33745a4ad074697";
      MINIME_VAULT_KEY = "98ea4892878998a3badd3177a9d4ca61e33745a4ad074697";
      EMBEDDING_DEVICE = "cpu";
      EMBEDDING_MODEL = "nomic-ai/nomic-embed-text-v1.5";
      EMBEDDING_DIM = "768";
      TRUST_REMOTE_CODE = "1";
      MEMORY_PROCESSOR_MIN_WORKERS = "2";
      MEMORY_PROCESSOR_MAX_WORKERS = "8";
      CORS_ORIGINS = ''["http://localhost:9001","http://127.0.0.1:9001","http://192.168.49.50:9001","http://192.168.49.50"]'';
    };
  };

  services.nginx = {
    # CORS maps for the MCP endpoint (see recalliumMcpLocation above). The
    # container's own CORSMiddleware only permits its fixed CORS_ORIGINS list
    # and answers 400 to preflights from any other origin, which breaks
    # browser-based MCP clients — nginx owns CORS here instead.
    appendHttpConfig = ''
      map $http_origin $cors_origin {
        default $http_origin;
        "" "*";
      }
      map $http_access_control_request_headers $cors_request_headers {
        default $http_access_control_request_headers;
        "" "content-type, accept, mcp-protocol-version, mcp-session-id, authorization";
      }
    '';

    virtualHosts = {
      # ---- IP vhost (192.168.49.50): the path-based /recallium* layout. ----

      "192.168.49.50".locations = {
        "= /recallium" = {
          return = "301 /recallium/";
        };

        "/recallium/" = recalliumUiLocation;

        # Stable LLM endpoint for Recallium's OpenAI provider (container's
        # base_url in llm_provider_accounts id 3 is fixed at
        # http://host.containers.internal/recallium-llm). The prefix is
        # stripped and the call is proxied to the llama-swap router of the GPU
        # selected by config.ai.recalliumGpu (./default.nix). Switching GPUs =
        # edit that option + rebuild; no DB changes needed.
        "/recallium-llm/" = {
          proxyPass = "http://127.0.0.1:8081";
          extraConfig = ''
            rewrite ^/recallium-llm/?(.*)$ /upstream/${config.ai.recalliumGpu}/v1/$1 break;
            # LLM calls can take minutes (model load, long generations).
            proxy_read_timeout 600s;
            proxy_send_timeout 600s;
          '';
          recommendedProxySettings = true;
        };

        # The Recallium UI derives its API base URL from the page's origin
        # (apiUrl = protocol + "//" + window.location.host in its bundle), so
        # when served via this host it calls http://192.168.49.50/api/...
        # Catch-all for the Recallium REST API: its UI uses /api/memories,
        # /api/projects, /api/setup, /api/providers, /api/documents — none of
        # which collide with the llama-swap paths carved out in llama-swap.nix.
        # Forward to the container's UI port, which serves the same API as the
        # 8001 port.
        "/api/" = {
          proxyPass = "http://127.0.0.1:9001";
          recommendedProxySettings = true;
          extraConfig = ''
            # LLM-backed UI requests can take minutes.
            proxy_read_timeout 600s;
            proxy_send_timeout 600s;
          '';
        };

        # Recallium MCP endpoint (MCP clients: http://192.168.49.50/recallium-mcp)
        "/recallium-mcp" = recalliumMcpLocation;
      };

      # ---- Public subdomains ----

      # Recallium UI + REST API at the root — no /recallium prefix, so no
      # sub_filter (the app runs at the root where its /ui redirect and asset
      # paths resolve natively, and the UI derives its API base from the page
      # origin, i.e. https://recallium.ai.chrisdell.info/api/...).
      "recallium.ai.chrisdell.info" = {
        useACMEHost = "ai.chrisdell.info";
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://127.0.0.1:9001";
          recommendedProxySettings = true;
          proxyWebsockets = true;
          extraConfig = ''
            # LLM-backed UI requests can take minutes.
            proxy_read_timeout 600s;
            proxy_send_timeout 600s;
          '';
        };
      };

      # Recallium MCP endpoint (Streamable HTTP). Same CORS handling as the
      # shared /recallium-mcp location.
      "recallium-mcp.ai.chrisdell.info" = {
        useACMEHost = "ai.chrisdell.info";
        forceSSL = true;
        locations."/" = recalliumMcpLocation;
      };
    };
  };
}
