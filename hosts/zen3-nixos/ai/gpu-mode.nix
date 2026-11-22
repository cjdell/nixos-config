{
  config,
  lib,
  pkgs,
  ...
}:

# `gpu-mode` — one command that hands the R9700 to exactly one thing:
#
#   gpu-mode llm     Strata (the boot default)
#   gpu-mode sd      the Flux-schnell sd-server (./sd-server.nix)
#   gpu-mode game    stop everything, 32 GiB of VRAM free for gaming
#   gpu-mode         status: who holds the card right now
#
# The lease is enforced by which units are RUNNING: strata.service has
# wantedBy (./strata.nix), sd-server.service deliberately has none
# (./sd-server.nix) — only gpu-mode starts it, and it waits for the model to
# actually load. If an LLM reload ever lands next to a running sd lease,
# Strata's `before_load` hook stops sd-server first (./strata.nix), so the
# two never fight over VRAM. See ./gpu-mode.sh for the script's own
# documentation.
#
# No polkit is needed: sudo is passwordless for wheel on this host
# (common/system.nix), and the script calls /run/wrappers/bin/sudo.

{
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "gpu-mode" ''
      export PATH=${
        lib.makeBinPath [
          pkgs.coreutils
          pkgs.curl
          pkgs.gnugrep
          pkgs.gnused
          pkgs.rocmPackages.amdsmi
          pkgs.systemd
        ]
      }:/run/setuid-programs
      # The LLM engine units, straight from the Nix list that generates them
      # (./strata.nix: ai.strataEngineUnits, primary first). The swap shim can
      # run one engine per selectable model, so the lease has to stop ALL of
      # them — hardcoding "strata strata-second" here is how a third model
      # would silently survive 'gpu-mode sd|game' and re-grab the card.
      export GPU_MODE_LLM_UNITS="${lib.concatStringsSep " " config.ai.strataEngineUnits}"
      exec ${pkgs.bash}/bin/bash ${./gpu-mode.sh} "$@"
    '')
  ];
}
