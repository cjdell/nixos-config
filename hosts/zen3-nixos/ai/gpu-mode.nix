{ lib, pkgs, ... }:

# `gpu-mode` — one command that hands the R9700 to exactly one thing:
#
#   gpu-mode llm     Avalon (the boot default)
#   gpu-mode sd      the on-demand Stable Diffusion stack (./sd-gate.nix)
#   gpu-mode game    stop everything, 32 GiB of VRAM free for gaming
#   gpu-mode         status: who holds the card right now
#
# The lease is enforced by which units are RUNNING: avalon.service has
# wantedBy (./avalon.nix), sd-gate.service deliberately has none
# (./sd-gate.nix) — only gpu-mode starts it. llama.cpp's server has no unload
# endpoint (Strata's cooperative POST /v1/unload is gone), so stopping
# avalon.service IS the eviction: sd/game mode take the card back
# unambiguously, and an ad-hoc overlap just runs SD at GTT-spill speed.
# See ./gpu-mode.sh for the script's own documentation.
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
          pkgs.gnugrep # in_flight() greps /slots; grep is NOT in coreutils
          pkgs.gnused
          pkgs.rocmPackages.amdsmi
          pkgs.systemd
        ]
      }:/run/setuid-programs
      exec ${pkgs.bash}/bin/bash ${./gpu-mode.sh} "$@"
    '')
  ];
}
