{ lib, pkgs, ... }:

# AI services on zen3-nixos, one module per service in this directory.
# Each service file also owns its nginx reverse-proxy config (IP-vhost
# locations + its public *.ai.chrisdell.info subdomain vhost), so the proxy
# for a service lives with that service:
#   llama-swap.nix      - llama.cpp router matrix + llama./llm. subdomains
#   sd-gate.nix         - on-demand stable-diffusion.cpp server + sd. subdomain
#   llama-log-viewer.nix- log viewer web app + logs. subdomain
#   ollama-bridge.nix   - legacy Ollama-compatible bridge (no proxy)
#   recallium.nix       - Recallium container + recallium./recallium-mcp.
#   diamcp.nix          - diamcp container + mcp. subdomain
#
# The public TLS cert + the wildcard fallback vhost live in ../tls.nix;
# the subdomain vhosts use `useACMEHost = "ai.chrisdell.info"` to serve that
# same cert.

{
  imports = [
    ./diamcp.nix
    ./llama-log-viewer.nix
    ./llama-swap.nix
    ./ollama-bridge.nix
    ./recallium.nix
    ./sd-gate.nix
  ];

  options.ai = {
    # Which GPU serves Recallium's LLM calls. Change this to switch the
    # target WITHOUT touching the Recallium DB: its base_url stays fixed at
    # http://host.containers.internal/recallium-llm -> nginx -> this GPU
    # (see locations."/recallium-llm/" in recallium.nix). Also picks the GPU
    # behind llm.ai.chrisdell.info (public LLM endpoint in llama-swap.nix).
    # Then `nixos-rebuild switch`.
    #   "r9700" -> the big R9700 (HIP, 32 GB)  [original setup]
    #   "rx580" -> the RX 580 (4 GB, Vulkan)   [current: Qwen3-4B-Instruct-2507]
    #   "vega"  -> the Vega 8 iGPU (GTT-backed)
    recalliumGpu = lib.mkOption {
      type = lib.types.str;
      default = "rx580";
      description = "llama-swap router (r9700|vega|rx580) serving Recallium's LLM calls";
    };
  };

  config = {
    environment.systemPackages = with pkgs; [
      rocmPackages.rocminfo
      rocmPackages.amdsmi
      # Vulkan build of stable-diffusion-cpp for the R9700 (nixpkgs default is
      # CPU-only). Same derivation sd-gate.nix spawns for sd-server.
      (stable-diffusion-cpp.override { vulkanSupport = true; })
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
  };
}
