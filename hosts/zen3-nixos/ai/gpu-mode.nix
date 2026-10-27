{ lib, pkgs, ... }:

# `gpu-mode` — one command that hands the R9700 to exactly one thing:
#
#   gpu-mode llm     Strata (the boot default)
#   gpu-mode sd      the on-demand Stable Diffusion stack (./sd-gate.nix)
#   gpu-mode game    stop everything, 32 GiB of VRAM free for gaming
#   gpu-mode         status: who holds the card right now
#
# The lease is enforced by which units are RUNNING: strata.service has
# wantedBy (./strata.nix), sd-gate.service deliberately has none
# (./sd-gate.nix) — only gpu-mode starts it. Both directions of an ad-hoc
# overlap resolve cooperatively instead of fighting: sd-gate posts to
# Strata's POST /v1/unload when it needs VRAM (Strata's serve layer then
# auto-reloads on the next LLM request), and Strata's `before_load` hook
# stops sd-gate before it reloads. See ./gpu-mode.sh for the script's own
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
          pkgs.gnused
          pkgs.rocmPackages.amdsmi
          pkgs.systemd
        ]
      }:/run/setuid-programs
      exec ${pkgs.bash}/bin/bash ${./gpu-mode.sh} "$@"
    '')
  ];
}
