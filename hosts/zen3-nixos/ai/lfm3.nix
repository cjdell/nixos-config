{
  config,
  lib,
  pkgs,
  llamaCppPkgs,
  ...
}:

# LFM3-1.7B on the RX 580 — the box's second, small LLM lane.
#
# The RX 580 (Ellesmere, PCI 1002:67df, renderD128) is the CONSOLE GPU: Plasma
# lives there, and it is NOT part of the gpu-mode R9700 lease. This unit is a
# plain always-on service on its own card, so it coexists with Strata: it can
# never touch the R9700's 32 GiB because the mesa device-select layer (see
# AGENTS.md "GPU pinning") hides it — MESA_VK_DEVICE_SELECT=1002:67df! exposes
# ONLY the RX 580 to this process, so Vulkan0 is always the 580 and Strata's
# VRAM is invisible to llama.cpp even by accident. Nothing here imports,
# restarts or reconfigures strata.service.
#
# Vulkan, not ROCm: gfx803 has been out of ROCm/HIP support for years (and
# Strata's ROCm-10 runtime override is deliberately strata-only); RADV serves
# it fine — verified on this card 2026-11-11: `llama-server --list-devices`
# with the pin shows `Vulkan0: AMD Radeon RX 580 Series (RADV POLARIS10)`.
#
# Why LFM3: Liquid's small hybrid (ConvNeXtr stem + gated short convs, 24
# transformer layers of which only 11 keep KV, 5 more sliding-window), Apache
# 2.0, native 256K. 1.02 GiB Q4_K_M weights decode comfortably on Polaris —
# this is the quick-lane model (subagents, summarisation, Recallium-style JSON
# chores) while Qwen3.8-Flash-Next owns the heavy lane on the R9700.
#
# ctx 32768, NOT the full 262144 the asus-i7-6700 lane pins: this card is
# 4096 MiB with ~3.6 GiB free under the running desktop, and the 256K KV
# commit measured there was ~3.4 GiB on top of the weights (asus: 4457 MiB
# idle incl. 1049 MiB weights). 32768 ctx adds only ~426 MiB of KV
# (13.3 KiB/token at this depth), so the whole server sits at ~1.8 GiB of the
# 4 GiB — headroom for desktop spikes, no GTT spill, no amdgpu lockup on the
# console GPU. One --ctx-size line up later if the card proves it can spare
# more.
#
# Model file from scripts/fetch-lfm3-1.7b.sh (rev + size + sha256 pinned);
# ConditionPathExists keeps the unit down until it is there, same guard as
# ./sd-server.nix.
#
# URL layout follows the other services: web UI + OpenAI API at the root of
# lfm3.ai.chrisdell.info (wildcard cert, ../tls.nix), and /lfm3/ on the IP
# vhost prefix-stripped for scripts (http://192.168.49.50/lfm3/v1/...).

let
  models = "/home/cjdell/Models";

  # llamaCppPkgs.vulkan = the flake's llama-cpp input with
  # -DLLAMA_BUILD_TESTS=OFF (flake.nix); its pin must stay >= upstream
  # b11960 for lfm3 arch support (AGENTS.md) — current pin is HEAD.
  llama-server-vulkan = llamaCppPkgs.vulkan;

  lfm3Location = {
    proxyPass = "http://127.0.0.1:8086";
    recommendedProxySettings = true;
    extraConfig = ''
      # Streams must not buffer (the UI's chat SSE), and long agent streams
      # outrun the 60 s default.
      proxy_read_timeout 600s;
      proxy_send_timeout 600s;
      proxy_buffering off;
      client_max_body_size 16m;
    '';
  };
in
{
  systemd.services.lfm3 = {
    description = "llama.cpp Vulkan server (LFM3-1.7B) on the RX 580 (console GPU)";
    documentation = [ "https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF" ];
    after = [ "network.target" ];
    # Always on: a separate card from the leased R9700, ~1.8 GiB of the
    # 4 GiB it owns, so it never competes with Strata or the gpu-mode lease.
    wantedBy = [ "multi-user.target" ];

    # The whole "does not disrupt strata" guarantee lives here: with the
    # trailing `!` only the RX 580 is enumerated, so this process cannot even
    # see the R9700, let alone allocate on it. XDG_DATA_DIRS is the same
    # layer-search fix the R9700 pin uses (AGENTS.md "GPU pinning").
    environment = {
      XDG_DATA_DIRS = "/run/opengl-driver/share";
      MESA_VK_DEVICE_SELECT = "1002:67df!";
    };

    serviceConfig = {
      # Sampling follows the asus-i7-6700 lane (temp 0.1, top_k 50,
      # repeat penalty 1.1). --device is belt-and-braces over the pin above.
      ExecStart = ''
        ${llama-server-vulkan}/bin/llama-server \
          --model ${models}/LFM3-1.7B-Q4_K_M.gguf \
          --device Vulkan0 \
          --n-gpu-layers 99 --ctx-size 32768 \
          --host 127.0.0.1 --port 8086 --alias LFM3-1.7B \
          --temp 0.1 --top-k 50 --repeat-penalty 1.1
      '';
      ConditionPathExists = "${models}/LFM3-1.7B-Q4_K_M.gguf";
      # First start after a boot compiles RADV pipelines for the whole
      # Vulkan shader set on Polaris — slower than the model read itself.
      TimeoutStartSec = "5min";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  services.nginx.virtualHosts = {
    # ---- IP vhost (192.168.49.50): API-only prefix, like /sd-api/. ----
    # The web UI's absolute paths do not survive a prefix, so this location
    # is for scripts: http://192.168.49.50/lfm3/v1/chat/completions etc.
    # The UI itself is on the subdomain.

    "192.168.49.50".locations = {
      "/lfm3/" = {
        proxyPass = "http://127.0.0.1:8086";
        recommendedProxySettings = true;
        extraConfig = ''
          rewrite ^/lfm3/?(.*)$ /$1 break;
          proxy_read_timeout 600s;
          proxy_send_timeout 600s;
          proxy_buffering off;
          client_max_body_size 16m;
        '';
      };
    };

    # ---- Public subdomain: UI at the root, OpenAI API under /v1/. ----

    "lfm3.ai.chrisdell.info" = {
      useACMEHost = "ai.chrisdell.info";
      forceSSL = true;
      locations."/" = lfm3Location;
    };
  };
}
