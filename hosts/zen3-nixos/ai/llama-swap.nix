{
  config,
  lib,
  pkgs,
  specialArgs,
  ...
}:

# llama-swap router matrix: three llama.cpp router instances (llama-server
# --models-dir), one per GPU, kept co-resident via a `matrix` so neither
# evicts the other. See AGENTS.md "The live target host" for the full story:
# r9700 (Vulkan build, --models-max 1, no GTT spill), vega (Vulkan, GTT,
# up to 4 resident), rx580 (Vulkan, 4 GB hard cap, 1 resident).
#
# nginx: owns the "/" location + llama-swap's /api management carve-outs on
# the IP vhost, plus the public llama.ai.chrisdell.info (UI + API at root,
# no carve-outs needed) and llm.ai.chrisdell.info (OpenAI-compatible
# endpoint for the GPU in config.ai.recalliumGpu) subdomains.

let
  # Everything under "/" goes to llama-swap. On the IP vhost the /api/...
  # carve-outs below must pre-empt the Recallium /api/ catch-all; on the
  # dedicated llama subdomain the root location is the only one, so no
  # carve-outs exist there.
  llamaRootLocation = {
    proxyPass = "http://127.0.0.1:8081";
    recommendedProxySettings = true;
    proxyWebsockets = true;
    extraConfig = ''
      # LLM generations, model loads, and long prefills before the first
      # token routinely exceed nginx's 60s default read timeout. OpenAI-style
      # SSE must also stream through un-buffered or clients see no tokens
      # until the buffer fills and time out on their own.
      proxy_read_timeout 600s;
      proxy_send_timeout 600s;
      proxy_buffering off;
    '';
  };
in
{
  systemd.services.llama-swap = {
    description = "Llama Swap";
    after = [ "wait-for-network.service" ];
    wants = [ "wait-for-network.service" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      # All three routers run the upstream Vulkan build (llama-cpp-vulkan).
      # The r9700 previously ran the stew675/llama.cpp `rdna-boosts` HIP fork;
      # its MTP speculative decoding showed no draft acceptance (spec_decode
      # counters stayed at 0 on the r9700), so it was switched to the Vulkan
      # build, where MTP works (verified 35/35 drafts accepted in the LM Studio
      # trial, 2026-08-23).
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
        # All three wrappers use the mesa device-select layer so their pinned
        # GPU is the only Vulkan device (always Vulkan0).
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
        # r9700: 1002:7551 (Navi 48) — the R9700 is the only visible device, so
        # `-dev Vulkan0` always means the R9700 (same scheme as vega/rx580).
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
          [Tiel-Coder-35B-A3B-GGUF-MTP]
          spec-type = draft-mtp
        '';

        # Native Nix structure representing the YAML config
        llamaConfig = {
          models = {
            # Router mode, API chooses the model but less tweakable. One entry
            # per GPU; each spawns its own llama.cpp router (llama-server
            # --models-dir) auto-loading GGUFs from /home/cjdell/Models on demand.
            #
            # r9700 = Radeon R9700 32 GB (device-select pinned to 1002:7551, also
            #         Vulkan0 in its own process): the big models. --models-max 1
            #         keeps ONE model resident at a time (no GTT spill).
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

  services.nginx.virtualHosts = {
    # ---- IP vhost (192.168.49.50): llama-swap's root + management API. ----

    "192.168.49.50".locations = {
      "/" = llamaRootLocation;

      # llama-swap's own management API. Its UI is served from the "/"
      # location (8081) and calls these same-origin /api/... endpoints, so
      # they must be carved out of Recallium's /api/ catch-all below —
      # otherwise nginx's longest-prefix match sends them to Recallium, which
      # 404s (that is what broke the UI's /api/events stream). Paths verified
      # from the llama-swap UI bundle: /api/events (SSE), /api/performance,
      # /api/version, /api/models/unload[/<name>], /api/captures/<id>.
      # If a future llama-swap version adds /api/ endpoints, list them here
      # or the UI will silently 404 via the Recallium catch-all.
      # (On llama.ai.chrisdell.info no carve-outs are needed — that vhost
      # sends every path, /api included, to 8081.)
      "= /api/events" = {
        proxyPass = "http://127.0.0.1:8081";
        recommendedProxySettings = true;
        extraConfig = ''
          # Long-lived SSE stream: unbuffered, don't time out while idle.
          proxy_read_timeout 600s;
          proxy_send_timeout 600s;
          proxy_buffering off;
        '';
      };

      "= /api/version" = {
        proxyPass = "http://127.0.0.1:8081";
        recommendedProxySettings = true;
      };

      "= /api/performance" = {
        proxyPass = "http://127.0.0.1:8081";
        recommendedProxySettings = true;
      };

      # Prefix match: covers /api/models/unload and /api/models/unload/<name>.
      "/api/models/unload" = {
        proxyPass = "http://127.0.0.1:8081";
        recommendedProxySettings = true;
      };

      "/api/captures/" = {
        proxyPass = "http://127.0.0.1:8081";
        recommendedProxySettings = true;
      };
    };

    # ---- Public subdomains (wildcard cert via useACMEHost, see ../tls.nix).
    #      nginx matches the exact server_name over the wildcard alias on the
    #      ai.chrisdell.info vhost. ----

    # llama-swap: UI + management API at the root — a dedicated host needs no
    # /api carve-outs. The OpenAI-compatible router endpoints stay reachable
    # at /upstream/<gpu>/v1.
    "llama.ai.chrisdell.info" = {
      useACMEHost = "ai.chrisdell.info";
      forceSSL = true;
      locations."/" = llamaRootLocation;
    };

    # Public OpenAI-compatible LLM endpoint for the GPU in
    # config.ai.recalliumGpu. Client base URL: https://llm.ai.chrisdell.info
    # (append /chat/completions, /models, ...). Change config.ai.recalliumGpu
    # in ./default.nix to serve a different GPU's router (r9700 for the big
    # models).
    "llm.ai.chrisdell.info" = {
      useACMEHost = "ai.chrisdell.info";
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:8081";
        recommendedProxySettings = true;
        extraConfig = ''
          rewrite ^/?(.*)$ /upstream/${config.ai.recalliumGpu}/v1/$1 break;
          # LLM calls can take minutes (model load, long generations).
          proxy_read_timeout 600s;
          proxy_send_timeout 600s;
        '';
      };
    };
  };
}
