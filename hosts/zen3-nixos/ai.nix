{
  config,
  lib,
  pkgs,
  specialArgs,
  ...
}:

let
  llama-log-viewer = pkgs.rustPlatform.buildRustPackage {
    pname = "llama-log-viewer";
    version = "0.1.0";
    src = ../../llama-log-viewer;
    cargoLock.lockFile = ../../llama-log-viewer/Cargo.lock;
    doCheck = false;
  };

  # nixpkgs default is a CPU-only build (SD_VULKAN=OFF); enable the Vulkan
  # backend for the R9700. Shared by systemPackages and the sd-gate unit.
  stable-diffusion-cpp-vulkan = pkgs.stable-diffusion-cpp.override { vulkanSupport = true; };

  # On-demand SD: always listens on 8084 (nginx /sd-api target), spawns
  # sd-server (8085) on the first request, kills it after --idle seconds of
  # no traffic so the R9700 VRAM is freed. See sd-gate/.
  sd-gate = pkgs.rustPlatform.buildRustPackage {
    pname = "sd-gate";
    version = "0.1.0";
    src = ../../sd-gate;
    cargoLock.lockFile = ../../sd-gate/Cargo.lock;
    doCheck = false;
  };

  # Static web UI for sd-server, copied into the store so nginx (non-root
  # user) can serve it — it cannot read /home/cjdell (mode 700).
  sd-webui = pkgs.runCommandLocal "sd-webui" { src = ../../sd-webui; } "cp -r $src $out";

  # Ollama-compatible API bridge in front of llama-swap's OpenAI endpoint.
  # Recallium (and other Ollama-only clients) talk to this on port 11434;
  # it translates to llama-swap's `/upstream/r9700/v1` OpenAI API (the R9700
  # router, which serves Recallium's coding model).
  ollama-bridge = pkgs.rustPlatform.buildRustPackage {
    pname = "ollama-bridge";
    version = "0.1.0";
    src = ../../ollama-bridge;
    cargoLock.lockFile = ../../ollama-bridge/Cargo.lock;
    doCheck = false;
  };
in
{
  environment.systemPackages = with pkgs; [
    rocmPackages.rocminfo
    rocmPackages.amdsmi
    # Vulkan build of stable-diffusion-cpp for the R9700 (nixpkgs default is CPU-only).
    stable-diffusion-cpp-vulkan
  ];

  # I think stable-diffusion-webui needs this
  systemd.tmpfiles.rules = [
    "L+    /opt/rocm   -    -    -    -    ${pkgs.rocmPackages.clr}"
    # Recallium container data dirs (container runs as uid 1000)
    "d /var/lib/recallium/data 0700 1000 1000 - -"
    "d /var/lib/recallium/wal 0700 1000 1000 - -"
    "d /var/lib/recallium/documents 0700 1000 1000 - -"
    "d /var/lib/recallium/secrets 0700 1000 1000 - -"
  ];

  # Stop crashes for large context sizes
  boot.kernelParams = [ "amdgpu.lockup_timeout=10000" ];

  systemd.services.llama-swap = {
    description = "Llama Swap";
    after = [ "wait-for-network.service" ];
    wants = [ "wait-for-network.service" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      HSA_OVERRIDE_GFX_VERSION = "9.0.0";
      # GGML_VK_LOG_SUBMISSIONS = "1";
      # GGML_VK_SERIALIZE_SUBMISSIONS = "1";
    };

    serviceConfig =
      let
        llama-cpp-vulkan = specialArgs.inputs.llama-cpp.packages.${pkgs.stdenv.hostPlatform.system}.vulkan;

        # Pin each router to its physical GPU via mesa's device-select layer
        # (VK_LAYER_MESA_device_select) instead of relying on llama.cpp's
        # `-dev VulkanN` indices. Those indices are assigned in RADV enumeration
        # order, which is NOT stable: the implicit layer reorders devices so the
        # boot-VGA (console) GPU comes first when no MESA_VK_DEVICE_SELECT is set.
        # The R9700 drives no screens (console lives on the iGPU), so `-dev Vulkan0`
        # silently meant the Vega and the r9700 router's models ran on the Vega's
        # GTT (30 GB GTT used, R9700 idle at 57 MB). Selecting by vendor:device ID
        # with a trailing `!` (exposes ONLY that device, making it Vulkan0) is
        # immune to enumeration/boot-VGA changes:
        #   1002:7551 = Radeon AI PRO R9700 (Navi 48, discrete, 32 GiB)
        #   1002:1638 = Cezanne Vega 8 iGPU
        #   1002:67df = Radeon RX 580 (Polaris, discrete, 4 GiB)
        # XDG_DATA_DIRS is required for the loader to discover the implicit layer
        # manifest under /run/opengl-driver/share/vulkan/implicit_layer.d.
        #
        # Three llama.cpp router instances (llama-server --models-dir), one per GPU:
        #
        #   r9700 (Radeon R9700 32 GB)  -> the big models. `--models-max 1`
        #     pins residency to a single model: the router unloads the current one
        #     and waits for the unload to finish before loading the next (LRU), so
        #     weights + KV always stay in VRAM and never spill to GTT.
        #   vega (Vega 8 iGPU, GTT-backed) -> the small/fast research
        #     sub-agent models. GTT overflow is fine here, so up to `--models-max 4`
        #     models can stay resident.
        #   rx580 (Radeon RX 580 4 GB) -> small models that fit in 4 GB, running
        #     fully in GDDR5 (~50 tok/s on a 2.6 B, faster than the Vega).
        #     `--models-max 1`: the 4 GB is a hard VRAM limit (no GTT headroom), so
        #     only one model stays resident at a time.
        #
        # All wrappers exec llama-server with the layer exposing a single device,
        # so all routers use `-dev Vulkan0` (the pinned GPU).
        #
        # `-cram N` (MiB) keeps idle-slot KV cache in system RAM and restores it to
        # VRAM on the next request with a matching prompt prefix (verified working on
        # the Vulkan backend: a 1243-token prefix reused ~1240 tokens, 16s -> 1.9s).
        # This is THE warm-start mechanism for the agent harness: at the old 8192
        # default the LCP cache logged "prompt state size ... exceeds cache size
        # limit, skipping", so every turn re-prefilled the whole context (~5 min,
        # longer than the client's 300 s stream idle timeout). 32 GiB was then
        # observed MAXED by the pi-ai harness (llama-server RSS sat at ~26.5 GiB,
        # LRU already evicting warm agent contexts), so it's doubled to 64 GiB:
        # ~13 x 100k-token contexts stay warm at q8_0 (vs ~6 before) - a returning
        # sub-agent's next turn skips its prefill entirely. Bounded and safe: LRU
        # evicts the oldest states first, and if a state alloc ever fails the cache
        # limit auto-shrinks to 40% of current size instead of OOMing (93 GiB RAM).
        # NOTE: do NOT switch to `-cram -1` here - that only removes the MiB cap,
        # the per-cache token cap (= --ctx-size) still binds, which is SMALLER.
        #
        # `--cache-reuse 256` enables KV-shifting chunk reuse: runs of >=256 tokens
        # that appear in a new prompt at a SHIFTED position (rolling-window contexts
        # that trim history from the front, reordered segments, ...) are shifted into
        # place instead of re-evaluated. Prefix reuse above already covers the common
        # "same system prompt + growing history" case; this covers the rest. Only
        # applies on shift-capable contexts (auto-disabled with a warning otherwise).
        #
        # `-ctk q8_0 -ctv q8_0` quantizes the KV cache: halves the VRAM/RAM footprint
        # of the context (12 GiB -> 6 GiB at 128K for REAP) with near-lossless quality.
        # The `-cram` RAM cache checkpoints store raw KV at the cache dtype, so it
        # shrinks too. f16 was the previous (default) cache type.
        #
        # Flash attention: NOT set explicitly - `-fa auto` (the default) probes the
        # backend and the Vulkan backend supports GGML_OP_FLASH_ATTN_EXT (incl. q8_0
        # KV), so it resolves to enabled. Explicit `-fa on` would skip the probe.
        #
        # `--models-preset` (mtpPresets below) enables `draft-mtp` speculative
        # decoding PER MODEL: the model's built-in MTP module drafts tokens, the
        # target model verifies. Must stay per-model — models without MTP tensors
        # (REAP, ornith, Laguna, LFM2.5...) fail to load if set globally. Verify
        # acceptance via the spec_decode_* counters on /metrics.
        # The layer is discoverable via XDG_DATA_DIRS; the `!` makes the pinned
        # device the only one exposed (so its ggml name is always Vulkan0).
        llama-r9700 = pkgs.writeShellScript "llama-r9700" ''
          export XDG_DATA_DIRS=/run/opengl-driver/share
          export MESA_VK_DEVICE_SELECT=1002:7551!
          exec ${llama-cpp-vulkan}/bin/llama-server "$@"
        '';

        llama-vega = pkgs.writeShellScript "llama-vega" ''
          export XDG_DATA_DIRS=/run/opengl-driver/share
          export MESA_VK_DEVICE_SELECT=1002:1638!
          exec ${llama-cpp-vulkan}/bin/llama-server "$@"
        '';

        llama-rx580 = pkgs.writeShellScript "llama-rx580" ''
          export XDG_DATA_DIRS=/run/opengl-driver/share
          export MESA_VK_DEVICE_SELECT=1002:67df!
          exec ${llama-cpp-vulkan}/bin/llama-server "$@"
        '';

        # `--sse-ping-interval 10`: while the stream is silent (i.e. during long
        # prompt processing), emit an SSE comment ping every 10 s so streaming
        # clients with first-token idle timeouts don't give up. Comment lines are
        # invisible to SSE parsers. Default is 30 s; the pi-ai harness dies at 300 s
        # of silence, which a 100k+ token prefill exceeds.
        llamaCmdR9700 = "${llama-r9700} --tools all --host 127.0.0.1 --port \${PORT} -dev Vulkan0 -t 12 -ngl all --models-dir ${modelsPath} --models-max 1 -cram 65536 --cache-reuse 256 -ctk q8_0 -ctv q8_0 --ctx-size ${toString (256 * 1024)} --metrics --reasoning-preserve --sse-ping-interval 10 --log-prompts-dir /home/cjdell/nixos-config/llama-logs --models-preset ${mtpPresets}";
        llamaCmdVega = "${llama-vega} --tools all --host 127.0.0.1 --port \${PORT} -dev Vulkan0 -t 4 -ngl all --models-dir ${modelsPath} --models-max 4 -cram 32768 --cache-reuse 256 -ctk q8_0 -ctv q8_0 --ctx-size ${toString (256 * 1024)} --metrics --reasoning-preserve --sse-ping-interval 10 --log-prompts-dir /home/cjdell/nixos-config/llama-logs --models-preset ${mtpPresets}";

        # rx580: small models fully in 4 GB GDDR5. --models-max 1 because the 4 GB
        # is a hard VRAM limit (no GTT headroom); -cram 16384 keeps idle-slot KV
        # warm in system RAM.
        llamaCmdRx580 = "${llama-rx580} --tools all --host 127.0.0.1 --port \${PORT} -dev Vulkan0 -t 8 -ngl all --models-dir ${modelsPath} --models-max 1 -cram 16384 --cache-reuse 256 -ctk q8_0 -ctv q8_0 --ctx-size ${toString (128 * 1024)} --metrics --reasoning-preserve --sse-ping-interval 10 --log-prompts-dir /home/cjdell/nixos-config/llama-logs --models-preset ${mtpPresets}";

        modelsPath = "/home/cjdell/Models";

        # Per-model speculative decoding presets for the inner llama.cpp routers.
        # `draft-mtp` reuses the model's own MTP module (`blk.N.nextn.*` tensors) as
        # the draft — no separate draft model, no extra VRAM. Only MTP-capable models
        # are listed; everything else loads without speculation.
        mtpPresets = pkgs.writeText "llama-mtp-presets" ''
          version = 1

          [Qwen3.8-27B-UD-Q4_K_XL]
          spec-type = draft-mtp
          [Qwen3.8-27B-UD-Q5_K_XL]
          spec-type = draft-mtp
          [Qwen3.8-27B-Q4_K_S]
          spec-type = draft-mtp
          [Qwen3.6-35B-A3B-UD-Q3_K_XL]
          spec-type = draft-mtp
          [DeepSeek-V4-Pro-Qwen3.5-9B-MTP-Q4_K_M]
          spec-type = draft-mtp
          [Qwen3.6-27B-Fable-Fus-711-UnHeretic-NM-DAU-NEO-MAX-NEO-MTP-Q4_K_M]
          spec-type = draft-mtp
        '';

        # Native Nix structure representing the YAML config
        llamaConfig = {
          models = {
            # Router mode, API chooses the model but less tweakable. One entry
            # per GPU; each spawns its own llama.cpp router (llama-server
            # --models-dir) auto-loading GGUFs from /home/cjdell/Models on demand.
            #
            # r9700 = Radeon R9700 32 GB (device-select pinned to 1002:7551, so it
            #         is Vulkan0): the big models. --models-max 1 keeps ONE model
            #         resident at a time (no GTT spill).
            # vega  = Vega 8 iGPU (device-select pinned to 1002:1638, also Vulkan0
            #         in its own process; GTT-backed): small research sub-agent
            #         models, up to 4 resident.
            # rx580 = Radeon RX 580 4 GB (device-select pinned to 1002:67df, also
            #         Vulkan0 in its own process): small models that fit in 4 GB,
            #         1 resident (hard VRAM limit).
            #
            # litellm routes: scouting -> /upstream/vega/v1, everything else
            # -> /upstream/r9700/v1 (see litellm.yaml). Add an rx580 route there if
            # you want litellm to send small-model traffic to it.
            "r9700" = {
              cmd = llamaCmdR9700;
            };

            "vega" = {
              cmd = llamaCmdVega;
            };

            "rx580" = {
              cmd = llamaCmdRx580;
            };
          };

          # Run all three routers in parallel. llama-swap's default is one model
          # at a time: without a matrix/groups it would evict whichever router is
          # running whenever another entry is requested, killing that GPU's
          # instance. Declaring them co-resident (`r & v & x`) means llama-swap
          # only starts the requested entry on first use and then keeps all three
          # llama-server router processes up side by side — each GPU serves its
          # own model pool independently.
          matrix = {
            vars = {
              r = "r9700";
              v = "vega";
              x = "rx580";
            };
            sets = {
              gpus = "r & v & x";
            };
          };
        };

        # Convert native Nix structure to YAML
        configYaml = lib.generators.toYAML { } llamaConfig;
      in
      {
        ExecStart = "${lib.getExe pkgs.llama-swap} -listen 0.0.0.0:8081 -config ${pkgs.writeText "llama-swap-config" configYaml}";
        WorkingDirectory = modelsPath;
        Restart = "always";
      };
  };

  # stable-diffusion.cpp runs on demand: sd-gate fronts port 8084 and only
  # keeps sd-server (and the SDXL model in VRAM) alive while it is used.
  # 120 s idle -> killed -> VRAM freed for llama-swap's resident model.
  systemd.services.sd-gate = {
    description = "On-demand stable-diffusion.cpp server (loads on first request, unloads when idle)";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    # Pin the spawned sd-server to the R9700 with the same device-select layer
    # pin as llama-swap: without MESA_VK_DEVICE_SELECT the layer's boot-VGA
    # default exposes the iGPU first and `--backend vulkan0` would put SDXL on
    # the Vega. With the pin, vulkan0 = the R9700 (the only visible device).
    environment = {
      XDG_DATA_DIRS = "/run/opengl-driver/share";
      MESA_VK_DEVICE_SELECT = "1002:7551!";
    };

    serviceConfig = {
      # --vae-tiling is required: RADV caps maxMemoryAllocationSize at ~4 GiB
      # on the R9700, and the SDXL VAE decode graph (~8.5 GB) OOMs without it.
      # --max-vram -1 sizes compute graphs to whatever VRAM is free so SD stays
      # polite next to llama-swap's resident model. See AGENTS.md.
      # --min-vram-gib 10: below 10 GiB free (i.e. the llama-swap LLM is
      # resident) the gate posts to llama-swap's /api/models/unload and waits
      # for the VRAM before loading SDXL. Status page: /sd-status/ via nginx.
      ExecStart = "${sd-gate}/bin/sd-gate --listen 127.0.0.1:8084 --status-listen 127.0.0.1:8086 --upstream 127.0.0.1:8085 --idle 120 --ready-timeout 180 --min-vram-gib 10 --vram-tool /run/current-system/sw/bin/amd-smi -- ${stable-diffusion-cpp-vulkan}/bin/sd-server --listen-ip 127.0.0.1 --listen-port 8085 --backend diffusion=vulkan0,clip=vulkan0,vae=vulkan0 --vae-tiling --max-vram -1 -m /home/cjdell/sd-models/sd_xl_base_1.0.safetensors --vae /home/cjdell/sd-models/sdxl_vae.fp16.safetensors --clip_l /home/cjdell/sd-models/clip_l.fp16.safetensors --clip_g /home/cjdell/sd-models/clip_g.fp16.safetensors";
      # Safety net: if the gate is SIGKILLed (stop timeout), kill the
      # sd-server it spawned so its VRAM is not left loaded.
      ExecStop = "${pkgs.bash}/bin/bash -c 'if [ -f /run/sd-gate.pid ]; then kill \"$(cat /run/sd-gate.pid)\" 2>/dev/null || true; rm -f /run/sd-gate.pid; fi'";
      Restart = "always";
      RestartSec = 5;
      TimeoutStopSec = 20;
    };
  };

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

  # Ollama-compatible bridge -> llama-swap (port 11434). Must listen on
  # 0.0.0.0 so the rootful podman Recallium container can reach it via
  # host.containers.internal.
  systemd.services.ollama-bridge = {
    description = "Ollama-compatible API bridge to llama-swap";
    after = [
      "llama-swap.service"
      "wait-for-network.service"
    ];
    wants = [ "wait-for-network.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      ExecStart = "${ollama-bridge}/bin/ollama-bridge --listen 0.0.0.0:11434 --upstream http://127.0.0.1:8081/upstream/r9700/v1";
      Restart = "always";
      RestartSec = 3;
    };
  };

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

  virtualisation.oci-containers.containers.diamcp = {
    hostname = "diamcp";
    image = "localhost/diamcp";
    autoStart = true;
    ports = [ "8082:8000" ];
    volumes = [
      "/home/cjdell:/workspace"
    ];
    extraOptions = [
      "--user=${toString config.users.users.cjdell.uid}:100"
    ];
  };

  services.nginx = {
    # CORS maps for the Recallium MCP endpoint (see locations."/recallium-mcp").
    # The container's own CORSMiddleware only permits its fixed CORS_ORIGINS
    # list and answers 400 to preflights from any other origin, which breaks
    # browser-based MCP clients. nginx owns CORS here instead.
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
      "192.168.49.50" = {
        locations."/" = {
          proxyPass = "http://127.0.0.1:8081";
          recommendedProxySettings = true;
          proxyWebsockets = true;
          extraConfig = ''
            # LLM generations, model loads, and long prefills before the first
            # token routinely exceed nginx's 60s default read timeout.
            # OpenAI-style SSE must also stream through un-buffered or clients
            # see no tokens until the buffer fills and time out on their own.
            proxy_read_timeout 600s;
            proxy_send_timeout 600s;
            proxy_buffering off;
          '';
        };

        locations."/mcp" = {
          proxyPass = "http://127.0.0.1:8082/mcp";
          recommendedProxySettings = true;
          proxyWebsockets = true;
          extraConfig = ''
            # Container tool calls can run long; don't let nginx time out.
            proxy_read_timeout 600s;
            proxy_send_timeout 600s;
            proxy_buffering off;
          '';
        };

        locations."/logs" = {
          # Strip the /logs prefix explicitly, then proxy without a URI so
          # nginx forwards the rewritten path (e.g. /logs/api/stats -> /api/stats)
          proxyPass = "http://127.0.0.1:8083";
          extraConfig = ''
            rewrite ^/logs/?(.*)$ /$1 break;
          '';
          recommendedProxySettings = true;
          proxyWebsockets = true;
        };

        # stable-diffusion.cpp web UI + API (http://192.168.49.50/sd/)
        locations."= /sd" = {
          return = "301 /sd/";
        };

        locations."/sd/" = {
          alias = "${sd-webui}/";
          index = "index.html";
        };

        locations."/sd-api/" = {
          # Strip the /sd-api prefix, then proxy without a URI so nginx
          # forwards the rewritten path (e.g. /sd-api/sdapi/v1/txt2img ->
          # /sdapi/v1/txt2img on sd-server port 8084).
          proxyPass = "http://127.0.0.1:8084";
          extraConfig = ''
            rewrite ^/sd-api/?(.*)$ /$1 break;
            # SD generations take tens of seconds; don't let nginx time out.
            proxy_read_timeout 600s;
            proxy_send_timeout 600s;
          '';
          recommendedProxySettings = true;
        };

        # sd-gate status page: why is the model loaded? (state, idle-unload
        # countdown, VRAM, active clients). JSON at /sd-status/status.
        locations."= /sd-status" = {
          return = "301 /sd-status/";
        };

        locations."/sd-status/" = {
          proxyPass = "http://127.0.0.1:8086";
          extraConfig = ''
            rewrite ^/sd-status/?(.*)$ /$1 break;
          '';
          recommendedProxySettings = true;
        };

        # Redirect bare /logs to /logs/ so relative URLs resolve inside the app
        locations."= /logs" = {
          return = "301 /logs/";
        };

        # Recallium web UI (direct access: http://192.168.49.50:9001)
        locations."= /recallium" = {
          return = "301 /recallium/";
        };

        locations."/recallium/" = {
          # Strip the /recallium prefix explicitly, then proxy without a URI.
          proxyPass = "http://127.0.0.1:9001";
          extraConfig = ''
            rewrite ^/recallium/?(.*)$ /$1 break;
            # The Recallium UI is an Express app that redirects its root to a
            # *relative* /ui path. Rewrite those relative Locations back under
            # the /recallium prefix, otherwise the browser follows the first
            # hop to /ui and lands on llama-swap (nginx's "/" location).
            proxy_redirect / /recallium/;
            # The app's HTML/JS also emit *absolute* /ui/... references
            # (asset tags, chunk URLs, images, the router basename) which the
            # proxy_redirect above does NOT touch (headers only). Rewrite those
            # in the response body back under /recallium, else the browser
            # requests /ui/... and hits llama-swap's UI instead.
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

        # llama-swap's own management API. Its UI is served from the "/"
        # location (8081) and calls these same-origin /api/... endpoints, so
        # they must be carved out of the /api/ catch-all below — otherwise
        # nginx's longest-prefix match sends them to Recallium, which 404s
        # (that is what broke the UI's /api/events stream). Paths verified
        # from the llama-swap UI bundle: /api/events (SSE), /api/performance,
        # /api/version, /api/models/unload[/<name>], /api/captures/<id>.
        # If a future llama-swap version adds /api/ endpoints, list them here
        # or the UI will silently 404 via the Recallium catch-all.
        locations."= /api/events" = {
          proxyPass = "http://127.0.0.1:8081";
          recommendedProxySettings = true;
          extraConfig = ''
            # Long-lived SSE stream: unbuffered, don't time out while idle.
            proxy_read_timeout 600s;
            proxy_send_timeout 600s;
            proxy_buffering off;
          '';
        };

        locations."= /api/version" = {
          proxyPass = "http://127.0.0.1:8081";
          recommendedProxySettings = true;
        };

        locations."= /api/performance" = {
          proxyPass = "http://127.0.0.1:8081";
          recommendedProxySettings = true;
        };

        # Prefix match: covers /api/models/unload and /api/models/unload/<name>.
        locations."/api/models/unload" = {
          proxyPass = "http://127.0.0.1:8081";
          recommendedProxySettings = true;
        };

        locations."/api/captures/" = {
          proxyPass = "http://127.0.0.1:8081";
          recommendedProxySettings = true;
        };

        # The Recallium UI derives its API base URL from the page's origin
        # (apiUrl = protocol + "//" + window.location.host in its bundle), so
        # when served via this host it calls http://192.168.49.50/api/...
        # Catch-all for the Recallium REST API: its UI uses /api/memories,
        # /api/projects, /api/setup, /api/providers, /api/documents — none of
        # which collide with the llama-swap paths carved out above. Forward to
        # the container's UI port, which serves the same API as the 8001 port.
        locations."/api/" = {
          proxyPass = "http://127.0.0.1:9001";
          recommendedProxySettings = true;
          extraConfig = ''
            # LLM-backed UI requests can take minutes.
            proxy_read_timeout 600s;
            proxy_send_timeout 600s;
          '';
        };

        # Recallium MCP endpoint (MCP clients: http://192.168.49.50/recallium-mcp)
        #
        # CORS is handled here, not by the app: answer OPTIONS preflights
        # locally (the app 400s preflights from origins outside CORS_ORIGINS)
        # and stamp CORS headers on every response, echoing the request origin
        # so credentialed requests work too. The upstream's own CORS headers are
        # hidden to avoid duplicates.
        locations."/recallium-mcp" = {
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
      };
    };
  };
}
