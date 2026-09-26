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
#   alexandria.nix      - Alexandria audiobook container (ROCm on the R9700, port 4200) + alexandria. subdomain
#   gpu-panel.nix       - GPU telemetry/overdrive/PID-fan web panel + gpu. subdomain
#
# The public TLS cert + the wildcard fallback vhost live in ../tls.nix;
# the subdomain vhosts use `useACMEHost = "ai.chrisdell.info"` to serve that
# same cert.

{
  imports = [
    # ./alexandria.nix
    # ./diamcp.nix
    ./gpu-panel.nix
    # ./llama-log-viewer.nix
    ./llama-swap.nix
    # ./ollama-bridge.nix
    # ./recallium.nix
    # ./sd-gate.nix
  ];

  options.ai = {
    # Which llama-swap router serves Recallium's and litellm's LLM calls. It
    # also picks the backend behind llm.ai.chrisdell.info (public
    # OpenAI-compatible endpoint, see llama-swap.nix).
    #
    # "r9700" is the only router that exists since 2026-09-26 (the vega and
    # rx580 routers were removed - too slow / too little VRAM); the option is
    # kept so the routing is explicit and a second GPU could be added back
    # without editing every consumer.
    recalliumGpu = lib.mkOption {
      type = lib.types.str;
      default = "r9700";
      description = "llama-swap router (r9700) serving Recallium's/litellm's LLM calls";
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
