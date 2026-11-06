{ lib, pkgs, ... }:

# AI services on zen3-nixos, one module per service in this directory.
# Each service file also owns its nginx reverse-proxy config (IP-vhost
# locations + its public *.ai.chrisdell.info subdomain vhost), so the proxy
# for a service lives with that service:
#   llama-swap.nix      - llama.cpp router matrix + llama./llm. subdomains
#                         (DISABLED while ./avalon.nix runs - see the import list)
#   avalon.nix          - Avalon llama-server fork (HIP/gfx1201) on :8080 - the
#                         Qwen3.8-Flash-Next server since 2026-11-04
#   strata.nix          - Strata engine (HIP/gfx1201) + serve + strata. subdomain
#                         (DISABLED since 2026-11-04, superseded by ./avalon.nix)
#   sd-gate.nix         - on-demand stable-diffusion.cpp server + sd. subdomain
#                         (started by gpu-mode, NOT at boot)
#   gpu-mode.nix        - the `gpu-mode` command: lease the R9700 to llm / sd /
#                         game (see ./gpu-mode.sh)
#   llama-log-viewer.nix- log viewer web app + logs. subdomain
#   ollama-bridge.nix   - legacy Ollama-compatible bridge (no proxy)
#   recallium.nix       - Recallium container + recallium./recallium-mcp.
#                         (its LLM calls ride on ./avalon.nix via /recallium-llm)
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
    ./gpu-mode.nix
    # Re-enabled 2026-11-04 while Avalon was live (it passes
    # --log-prompts-dir). Under Strata nothing new is written to llama-logs/,
    # so the viewer keeps serving the historical index; harmless either way.
    ./llama-log-viewer.nix
    # llama-swap is DISABLED while the single-model Qwen3.8-Flash-Next server
    # runs: both want the R9700's VRAM and tens of GB of RAM, and that server
    # exists to run a model llama.cpp (stock) cannot fit. Re-enable this import
    # only by also disabling ./strata.nix below.
    # ./llama-swap.nix
    # Strata (./strata.nix) is the model server again since 2026-11-04: it was
    # superseded by ./avalon.nix that morning and rolled back the same day.
    # ai.strataModel is still "ud-iq4-xs" (below), so no pack flip-back was
    # needed. To flip engines: swap the two imports below - and revert
    # ./gpu-mode.sh + ./sd-server.nix to the matching era's version from git
    # history: the lease is engine-specific (Strata: /v1/status + POST
    # /v1/unload; Avalon: /health + /slots + unit-state eviction). Never
    # import both - they double-bind :8080.
    ./strata.nix
    # ./avalon.nix
    # ./ollama-bridge.nix
    ./recallium.nix
    # SD shares the card with Strata via the gpu-mode lease (./gpu-mode.nix):
    # the service exists, starts only when asked (no wantedBy), and Strata's
    # before_load hook stops it if an LLM reload ever lands on the lease.
    # (Replaces ./sd-gate.nix, retired 2026-11-06 with the move to Flux.)
    ./sd-server.nix
  ];

  options.ai = {
    # Which llama-swap router serves litellm's LLM calls. It also picks the
    # backend behind llm.ai.chrisdell.info (public OpenAI-compatible endpoint,
    # see llama-swap.nix).
    #
    # ⚠️ Recallium no longer follows this: llama-swap is disabled while Strata
    # runs, and Recallium's /recallium-llm proxy now goes straight to Strata on
    # 127.0.0.1:8080 (see ./recallium.nix). This option is only read by
    # ./llama-swap.nix, so it is dead config until that import comes back.
    #
    # "r9700" is the only router that exists since 2026-09-26 (the vega and
    # rx580 routers were removed - too slow / too little VRAM); the option is
    # kept so the routing is explicit and a second GPU could be added back
    # without editing every consumer.
    recalliumGpu = lib.mkOption {
      type = lib.types.str;
      default = "r9700";
      description = "llama-swap router (r9700) serving litellm's LLM calls (unused while llama-swap is disabled)";
    };

    # Which Qwen3.8-Flash-Next build Strata serves (see ./strata.nix, which
    # carries the GGUF/pack paths and the per-model engine args for each).
    # Both packs are prepared by hand under /home/cjdell/Strata/pack, and the
    # unit's ConditionPathExists refuses to start one that has not been built,
    # so switching is one line + a rebuild - never a surprise at boot.
    #   "iq3s"       GSQ-RCO IQ3_S, 78 GB, all experts in RAM (live since
    #                2026-10-06; docs/strata.md)
    #   "ud-iq4-xs"  Unsloth UD-IQ4_XS, 93.7 GB, ~4-bit dynamic: +8.6 GiB of
    #                experts and a smaller GPU expert cache, so slower at long
    #                context (docs/strata.md "UD-IQ4_XS")
    #   "ud-iq4-xs-v31"
    #                Unsloth's "Dynamic v3.1" re-cut of that same quant (2026-11-04):
    #                four shards instead of three, 345 of 1224 tensors re-typed and
    #                33 expert layers moved to Q5_0.  Needs the engine 0.1.57 that
    #                ships with Strata 0.2.11.
    strataModel = lib.mkOption {
      type = lib.types.enum [
        "iq3s"
        "ud-iq4-xs"
        "ud-iq4-xs-v31"
      ];
      default = "iq3s";
      description = "the quant Strata serves: iq3s (GSQ-RCO) or ud-iq4-xs[-v31] (Unsloth)";
    };
  };

  config = {
    # The quant this box serves. Both packs are built by hand under
    # /home/cjdell/Strata/pack and the unit's ConditionPathExists refuses to
    # start one that is not there, so moving between them is this one line + a
    # rebuild.  ud-iq4-xs since 2026-10-09 (docs/strata.md "UD-IQ4_XS"), and
    # its "Dynamic v3.1" re-cut since 2026-11-05 - packed same day, 35 layers
    # with gate/up/down split across shards (native_experts v4, engine 0.1.57).
    # The old three-shard GGUFs and pack/ud-iq4-xs were deleted once v31 was
    # verified live, so "ud-iq4-xs" below is a schema entry only - switching
    # back to it means re-running scripts/fetch-strata-udiq4xs.sh + repack.
    ai.strataModel = "ud-iq4-xs-v31";

    environment.systemPackages = with pkgs; [
      rocmPackages.rocminfo
      rocmPackages.amdsmi
      # Vulkan build of stable-diffusion-cpp for the R9700 (nixpkgs default is
      # CPU-only). Same derivation ./sd-server.nix runs as a service.
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
