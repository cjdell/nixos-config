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
# ctx 131072 — raised from 32768 on 2026-11-11 on request, at the more
# deliberate end of this card's range. The RX 580 is 4096 MiB with ~3.6 GiB
# free under Plasma. Two measured points fit one line (asus-i7-6700 lane:
# 262144 ctx -> 4457 MiB idle incl. the 1049 MiB weights; here: 32768 ->
# ~1542 MiB): fixed ~1126 MiB (weights + graphs; LFM3 keeps KV on only 11 of
# 24 layers, 5 more sliding-window) + ~12.99 KiB/token. So 131072 commits
# ~2.8 GiB total and leaves ~800 MiB of slack — snug but sound. Hard ceiling
# is ~185-190K; do NOT chase it: that slack is what keeps a Plasma memory
# grab off the GTT (a console-GPU spill wedges the desktop, and
# amdgpu.lockup_timeout=10s reaps it visibly). The full 262144 native window
# CANNOT fit 4 GiB anyway — and chasing big ctx makes little sense either,
# since cold prefill here is ~90-220 tok/s, so a 131K prompt is already a
# 10-25 minute first token.
# NB: with kv_unified the --ctx-size pool is committed ONCE and llama-server's
# 4 slots share it — n_slots does NOT multiply KV memory (verified: 32K ctx
# committed ~426 MiB, matching 32768 x 12.99 KiB once, at n_slots = 4).
#
# Model file from scripts/fetch-lfm3-1.7b.sh (rev + size + sha256 pinned);
# ConditionPathExists keeps the unit down until it is there, same guard as
# ./sd-server.nix.
#
# Server-side tools (--tools all): llama.cpp's built-in agent tools
# (read_file, file_glob_search, grep_search, exec_shell_command, write_file,
# edit_file, get_info) execute INSIDE llama-server's own sandbox —
# --tools-runtime spins `podman run --rm -i docker.io/library/python:3.11-slim sh`
# at startup and routes every tool call through `podman exec` on it, so the
# model cannot read /home/cjdell or /run/secrets or exec anything on the host
# (verified: exec_shell_command sees the container's fs, /home/cjdell absent).
# Without that flag the tools run as the service user (root here) — that is
# remote code execution once the service is reachable, which is exactly why
# the sandbox is mandatory, not optional. The image is already in root's
# podman storage (recallium deps); llama.cpp would otherwise pull it.
# Usage contract (verified against pinned rev, tools/server/tests/unit/
# test_tools_builtin.py): GET /tools lists the schemas (feed them straight
# into a chat request's "tools" array); the chat turn returns finish_reason
# tool_calls and the CALLER executes them by POST /tools {"tool": ...,
# "params": ...} -> {"plain_text_response": ...}, then sends the result back
# as a tool message. The Web UI runs this loop automatically — built-in tool
# toggles appear there; API clients run the loop by hand. Enabling --tools
# also pins --cors-origins to localhost (browser origins only — irrelevant
# for API clients).
#
# MCP: llama.cpp's MCP client (#26062) speaks ONLY the stdio transport
# (child-process JSON-RPC), so Recallium/diamcp's Streamable-HTTP MCP cannot
# be wired in directly — only declare --mcp-servers-config commands you
# trust, they run with the server's (root) privileges. Not configured.
#
# URL layout follows the other services: web UI + OpenAI API at the root of
# lfm3.ai.chrisdell.info (wildcard cert, ../tls.nix), and /lfm3/ on the IP
# vhost prefix-stripped for scripts (http://192.168.49.50/lfm3/v1/...).
# The subdomain — the only public entry — is allow-listed to the private
# networks (hass-rs pattern on the router): with server-side tools enabled,
# "do not enable in untrusted environments" applies to the anonymous
# internet, sandbox or not (the sandbox bounds damage, not cost/DoS).
# The IP vhost needs no list: 192.168.49.50 is RFC1918, LAN-only by
# construction.

let
  models = "/home/cjdell/Models";

  # Image for llama.cpp's --tools-runtime sandbox (`podman run --rm -i <image> sh`).
  # Only needs sh/cat/wc/find — python:3.11-slim is already pulled in root's
  # podman store, so the sandbox starts without a network pull. FQ image ref:
  # podman's unqualified short names can fail on multi-registry search.
  toolsImage = "docker.io/library/python:3.11-slim";

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
    # llama.cpp spawns the tools sandbox via execvp("podman") on the SERVICE
    # PATH — which NixOS keeps minimal (coreutils/findutils/grep/sed/systemd) —
    # so podman must be added explicitly or the unit crash-loops with
    # "failed to spawn podman container for tools runtime".
    path = [ pkgs.podman ];
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
      # --tools all + the podman sandbox: see the header — never drop the
      # runtime flag while this endpoint is reachable beyond localhost.
      ExecStart = ''
        ${llama-server-vulkan}/bin/llama-server \
          --model ${models}/LFM3-1.7B-Q4_K_M.gguf \
          --device Vulkan0 \
          --n-gpu-layers 99 --ctx-size 131072 \
          --host 127.0.0.1 --port 8086 --alias LFM3-1.7B \
          --tools all --tools-runtime podman:${toolsImage} \
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
    # Allow-listed (hass-rs pattern): with --tools enabled this endpoint is an
    # agent runtime, and even sandboxed that is not something to hand to the
    # anonymous internet. LAN/VLAN/WG/tailnet/hackspace-IPv6 only. Note the
    # llama.cpp UI renders ANY non-2xx /props response as "API key required",
    # so a 403 here looks like auth to the user — it is this deny rule.

    "lfm3.ai.chrisdell.info" = {
      useACMEHost = "ai.chrisdell.info";
      forceSSL = true;
      locations."/" = lfm3Location;
      extraConfig = ''
        allow 127.0.0.1;
        allow ::1;
        allow 192.168.49.0/24;    # LAN
        allow 192.168.10.0/24;    # VLAN10
        allow 10.47.0.0/16;       # WireGuard
        allow 100.64.0.0/10;      # tailnet (headscale CGNAT range)
        allow 2a02:8010:6680:49::/64; # LAN's /64
        allow 2001:8b0:1d14::/48; # leighhack's IPv6 /48 (HACKSPACE_IPV6_SUBNET)
        deny all;
      '';
    };
  };
}
