{
  config,
  lib,
  pkgs,
  llamaCppPkgs,
  ...
}:

# gpu-mode — the two folding GeForce cards as a LEASE, the asus-i7-6700-nixos
# sibling of zen3-nixos' ai/gpu-mode.nix (same UX, fewer modes):
#
#   gpu-mode fold   Folding@home on both cards + all threads  (BOOT DEFAULT:
#                   fah-client.service is enabled; llama-server has no wantedBy)
#   gpu-mode llm    llama.cpp on the GTX 1060 (PCI 01:00.0), folding stopped
#   gpu-mode off    free the cards  (aliases: free, game)
#   gpu-mode        status: which unit holds what, per-card utilisation
#
# The lease is unit state, enforced by ./gpu-mode.sh. llm/off STOP
# fah-client.service outright (v8 has no trustworthy per-GPU switch — its DB,
# not config.xml, keeps settings), so nothing can auto-resume folding while
# llama.cpp holds the card; `fold` re-runs fah-client-configure (fah-provision)
# which also clears a Web Control pause. A reboot restores fold.
#
# Vulkan, not CUDA: CUDA 13's nvcc dropped Pascal/Maxwell (sm_61/sm_52), while
# the 580-branch proprietary driver's Vulkan ICD serves both cards. The engine
# is llamaCppPkgs.vulkan (the llama-cpp flake input via flake.nix) — it must
# carry lfm3 support (upstream b11960+), so the input pin must stay newer.
#
# No polkit needed: sudo is passwordless for wheel on this host, and the
# script calls /run/wrappers/bin/sudo (zen3 pattern).
{
  systemd.services.llama-server = {
    description = "llama.cpp Vulkan server (LFM3-1.7B) on the GTX 1060";
    documentation = [ "https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF" ];
    serviceConfig = {
      Type = "simple";
      User = "cjdell";
      Group = "users";
      Restart = "on-failure";
      # --device takes the Vulkan<idx> id from `llama-cli --list-devices`
      # (this box: Vulkan0 = HD 530, Vulkan1 = GTX 1060, Vulkan2 = GTX 970);
      # gpu-mode verifies via nvidia-smi that the server really landed on the
      # 1060's bus. Sampling follows the model card (temp 0.1, top_k 50,
      # repeat penalty 1.1). Swap --model for a new model in ~/Models.
      #
      # --ctx-size 262144 is the model's FULL trained window (LFM3 is native
      # 256K — no YaRN). Measured on the 6 GiB card 2026-10-31: the 1.02 GiB
      # weights + the whole KV commit at init (only 11 of 24 layers keep KV,
      # 5 more are sliding-window) sit at 4457 MiB idle and 4462 MiB with
      # 12K tokens filled — ~1.7 GiB of headroom, 74 tok/s decode at 12K
      # depth. There is no bigger ctx this model can run and it fits, so it
      # is pinned explicitly rather than via --fit.
      ExecStart = ''
        ${llamaCppPkgs.vulkan}/bin/llama-server \
          --model /home/cjdell/Models/LFM3-1.7B-Q4_K_M.gguf \
          --device Vulkan1 \
          --n-gpu-layers 99 --ctx-size 262144 \
          --host 0.0.0.0 --port 8080 --alias LFM3-1.7B \
          --temp 0.1 --top-k 50 --repeat-penalty 1.1
      '';
    };
    # Deliberately NO wantedBy — only gpu-mode starts it (sd-gate pattern),
    # so `fold` is what a reboot restores.
  };

  environment.systemPackages = [
    (pkgs.writeShellScriptBin "gpu-mode" ''
      export PATH=${
        lib.makeBinPath [
          pkgs.coreutils
          pkgs.curl
          pkgs.gawk
          pkgs.gnugrep
          pkgs.gnused
          pkgs.procps
          pkgs.systemd
          config.hardware.nvidia.package.bin
        ]
      }:/run/setuid-programs
      exec ${pkgs.bash}/bin/bash ${./gpu-mode.sh} "$@"
    '')
  ];
}
