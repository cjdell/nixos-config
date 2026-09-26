{
  config,
  lib,
  pkgs,
  specialArgs,
  ...
}:

# llama-swap in front of ONE llama.cpp router: an upstream Vulkan build
# (`llama-cpp-vulkan`, from the `llama-cpp` flake input =
# github:ggml-org/llama.cpp) pinned to the R9700. See AGENTS.md
# "The live target host: zen3-nixos".
#
# What was removed from here on 2026-09-26, and why:
#   * the vega (Vega 8 iGPU) and rx580 (RX 580 4 GB) routers, and the `matrix`
#     that kept all three llama-server routers co-resident. Both GPUs are too
#     slow / have too little VRAM to be useful next to the R9700.
#   * the local llama.cpp fork (`llama-cpp-mtp` = /home/cjdell/Projects/llama-mtp)
#     that the r9700 router ran for MTP. Upstream master carries
#     `--spec-type draft-mtp`; the fork only added the qwen4exp draft head,
#     whose model (Qwen3.8-Flash-Next, ~79 GB) cannot fit a 32 GiB card at all.
#     All llama.cpp forks are gone from flake.nix (llama-cpp-mtp,
#     llama-cpp-rdna, llama-cpp-uma) - upstream only, one router, one GPU.
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

    # NO GGML_VK_ALLOW_SYSMEM_FALLBACK here any more. It was set so that a model
    # that does not fit the card spills into GTT instead of failing the load -
    # but that silently turned the 27B's VRAM overflow into ~2 GB of
    # GTT-resident weights (measured 2026-09-26: 1995 MiB of GTT, byte-identical
    # over 707 samples and static from load time), i.e. PCIe-speed reads inside
    # every long prefill, which is exactly the "model fits fine on this GPU"
    # trap. A model that does not fit must now fail loudly. See docs/gtt-vram.md.

    serviceConfig =
      let
        llama-cpp-vulkan = specialArgs.llamaCppPkgs.vulkan;

        modelsPath = "/home/cjdell/Models";

        # Pin the router to the physical GPU via mesa's device-select implicit
        # layer (VK_LAYER_MESA_device_select) instead of llama.cpp's
        # `-dev VulkanN` index. Those indices follow RADV enumeration order,
        # which is NOT stable: the implicit layer puts the boot-VGA (console)
        # GPU first when nothing is forced, and the R9700 drives no screens, so
        # `-dev Vulkan0` silently meant the Vega's GTT. Selecting by
        # vendor:device ID is immune to enumeration/boot-VGA changes, and the
        # trailing `!` exposes ONLY that device - so Vulkan0 always means the
        # R9700 and no other GPU is even visible to the process.
        #   1002:7551 = Radeon AI PRO R9700 (Navi 48, discrete, 32 GiB)
        # XDG_DATA_DIRS is required for the loader to discover the implicit
        # layer manifest under /run/opengl-driver/share/vulkan/implicit_layer.d.
        llama-r9700 = pkgs.writeShellScript "llama-r9700" ''
          export XDG_DATA_DIRS=/run/opengl-driver/share
          export MESA_VK_DEVICE_SELECT=1002:7551!
          exec ${llama-cpp-vulkan}/bin/llama-server "$@"
        '';

        # Router mode (`--models-dir`): llama-server loads a GGUF from
        # /home/cjdell/Models on demand, named by its basename.
        #
        # --models-max 1    one model resident; a switch unloads the current one
        #                   first, so weights + KV of two models never have to
        #                   coexist in 32 GiB.
        # --parallel 1      ONE slot. Concurrent requests queue instead of
        #                   sharing the KV pool and the SMs. Measured 2026-09-26:
        #                   two simultaneous 24k-token cold prefills ran at 340
        #                   and 565 tok/s, the same prompt solo at 723 tok/s -
        #                   parallel long requests roughly halve each other.
        #                   (opencode's harness had 369 of 397 r9700 requests
        #                   overlapping another request; its title agent is now
        #                   disabled and nothing else fans out on purpose.)
        #                   Requests get SSE pings while queued, so a client's
        #                   idle timeout is not at risk from the queue itself.
        #
        # --ctx-size 196608 (192k), -ctk/-ctv q8_0
        #                   KV math for this model (Qwen3.8-27B = 17 attention
        #                   layers x 4 KV heads x (256 key + 256 value) values,
        #                   x 1.0625 B/value at q8_0 = 2176 B per layer per
        #                   token = 36992 B/token): 4.5 GiB at 128k, 6.8 GiB at
        #                   192k, 9.0 GiB at 256k - on top of the 18.7 GiB of
        #                   weights, against ~31.2 GiB usable on the 32 GiB card.
        #                   At 262144 with 4 slots it did NOT fit and ~2 GB went
        #                   to GTT; 192k leaves ~6 GiB for the compute graph(s)
        #                   and is deliberately kept in step with the
        #                   `limit.context` opencode is configured with, so the
        #                   client compacts before the server would refuse.
        #
        # -cram 32768       RAM prompt-cache cap in MiB (idle-slot KV states held
        #                   in system RAM, restored to VRAM when a prompt prefix
        #                   matches). This is THE warm-start mechanism: at the
        #                   8192 default llama.cpp logged "prompt state size ...
        #                   exceeds cache size limit, skipping" and every turn
        #                   re-prefilled the whole context (~5 min, longer than
        #                   the client's stream idle timeout). 32 GiB keeps ~4
        #                   long-context states. It is real RSS, not free: at the
        #                   old 65536 the box global-OOM'd llama-server 4x in
        #                   Aug 2026, hence the lower cap + the zramSwap cushion
        #                   in hosts/zen3-nixos/default.nix. Do NOT use `-cram -1`
        #                   (removes the MiB cap only; the per-state token cap
        #                   still binds).
        #
        # --cache-reuse 256 reuse runs of >=256 tokens that reappear at a shifted
        #                   position (front-trimmed rolling contexts, reordered
        #                   segments) by KV-shifting them into place instead of
        #                   re-evaluating; needs prompt caching.
        #
        # -fa (default `auto`) probes the backend; Vulkan supports
        #                   GGML_OP_FLASH_ATTN_EXT incl. q8_0 KV, so it resolves
        #                   to enabled. Nothing to set explicitly.
        #
        # --sse-ping-interval 10  emit an SSE comment ping every 10 s while the
        #                   stream is silent (i.e. during a long prefill) so
        #                   harnesses that die after 300 s of silence survive.
        #
        # --log-prompts-dir feeds the (currently disabled) llama-log-viewer.
        #
        # --models-preset  per-model draft-mtp speculation - see mtpPresets.
        llamaCmdR9700 = "${llama-r9700} --tools all --host 127.0.0.1 --port \${PORT} -dev Vulkan0 -t 12 -ngl all --models-dir ${modelsPath} --models-max 1 --parallel 1 -cram 32768 --cache-reuse 256 -ctk q8_0 -ctv q8_0 --ctx-size ${toString (192 * 1024)} --metrics --reasoning-preserve --sse-ping-interval 10 --log-prompts-dir /home/cjdell/nixos-config/llama-logs --models-preset ${mtpPresets}";

        # Per-model speculative decoding for the llama.cpp router, upstream
        # `--spec-type draft-mtp`: the model's own MTP module (blk.N.nextn.*
        # tensors) drafts tokens and the target verifies them - no separate
        # draft model, no extra VRAM. It must stay per-model: models without MTP
        # tensors fail to load if speculation is forced on. Verify real
        # acceptance with the spec_decode_* counters on /metrics (the r9700
        # Vulkan build was measured at ~88/92 drafts accepted on 2026-09-26).
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
          [Dirk-Qwen3.8-27B-UD-Q5_K_XL]
          spec-type = draft-mtp
        '';

        # Native Nix structure representing the llama-swap YAML config: one
        # model entry, i.e. one llama-server router on the R9700.
        # (No `matrix`/groups: those exist to keep several routers co-resident.)
        llamaConfig = {
          models = {
            "r9700" = {
              cmd = llamaCmdR9700;
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
