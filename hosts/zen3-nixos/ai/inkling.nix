{
  config,
  lib,
  pkgs,
  llamaCppPkgs,
  ...
}:

# Inkling-2-Mini on the R9700 — the llama.cpp lane of the strata-swap table.
#
# Thinking Machines' Inkling 2 Mini (released 2026-11-20, Apache 2.0): 26.2B
# MoE / 3.4B active (5.4B effective — layers 6-17 of 24 run THREE times with
# shared weights, so 48 layer-visits per token), 8 of 128 experts per layer,
# hybrid local/global attention (4 global layers of 24, sliding window 1024
# for the rest — the model card's 1M ctx comes cheap in KV: ~16.9 KB/token
# with q8_0 KV, because 40 of the 48 expanded cache layers are window-bounded),
# natively multimodal (ViT via mmproj). The GGML arch is `inkling2_loop`.
#
# WHY llama.cpp AND NOT STRATA. Strata is not a general GGUF engine: its
# kernels and pack pipeline are written for the Qwen3.8-Flash-Next family
# (qwen4exp) plus the Qwen3.6 own-path. A looped transformer with per-expert
# NVFP4 scales matches neither family — the engine has no inkling2 path at
# all. So this lane is stock llama.cpp (Vulkan build, like ./lfm3.nix — the
# R9700 goes through RADV, and it is pinned to the R9700 the same way the
# llama-swap/lfm3 units are: MESA_VK_DEVICE_SELECT=1002:7551! so Vulkan0 is
# always the leased card).
#
# HOW IT JOINS THE SWAP. The table itself lives in ./strata.nix (swapConfig);
# `ai.swapEngines` (./default.nix) lets an engine built OUTSIDE that file
# carry an entry, which strata-swap routes by `model` exactly like the Strata
# partners: request "inkling-2-mini-ud-q4_k_xl" on :8080 -> drain the live
# engine -> stop it -> wait for free VRAM -> start inkling.service -> wait
# /slots -> forward. Its unit joins ai.strataEngineUnits, so `gpu-mode
# sd|game` stops it too and `gpu-mode llm` evicts it back to the primary. It
# has NO wantedBy: a reboot still serves config.ai.strataModel.
#
# THE FILES. scripts/fetch-inkling-2-mini.sh puts them at
# /home/cjdell/Models/Inkling-2-Mini-GGUF and pins rev + size + sha256.
# They MUST be the Mainline_Support/ (`inkling2_loop`) layout renamed —
# the repo's root UD files use Unsloth's looped layout, which mainline
# reads as `inkling2` (unsupported), and the llama-cpp input must be
# >= upstream b12611 (#32704: loop passes 2/3 lost the per-expert NVFP4
# scales — SILENT garbage, ppl ~130, no load error). ConditionPathExists
# keeps the unit down until the fetch ran, as everywhere else here.
#
# VRAM: "the card, fully, without overflow" — the arithmetic of the line
# below, against this box's 32624 MiB (headless R9700, console is the RX 580):
#
#   weights (UD-Q4_K_XL)      17630 MiB   all 48 visits GPU-resident (-ngl 99;
#                                         17.6 GB is why Q4_K_XL, not Q8_K_XL:
#                                         Q8's 22.9 GB + KV cannot fit 512K)
#   KV @ 524288 ctx, q8_0      ~9400 MiB   8 full-history cache layers x 2 tensors
#                                         x 8 kv-heads x 128 dim x ~1.03 B;
#                                         windowed layers: ~90 MiB, constant
#   mmproj F16 (vision)          ~660 MiB
#   compute graphs/ubatch       ~3000 MiB  budget for -b 4096 -ub 1024 FA graphs
#                                         + Vulkan alloc slack
#   --------------------------------------------------------------
#   fully-loaded worst case     ~30.7 GiB of 31.4 — nothing sits idle, no GTT
#
# 524288 is deliberately NOT the model's 1M native window: 1M KV is ~18.7 GB
# and would overflow. 512K doubles the 256K ask with the KV pool fully
# committed, and lands inside the model card's own MRCR 256K-512K eval band.
# --parallel 1 (llama-server's default): the whole pool to one conversation;
# a second client queues instead of halving both streams (the strata-batch
# lesson, docs/strata-batching.md). No DSpark drafter: mainline support is
# still open PR #32218 — when it merges, add
# Mainline_Support/dspark-Inkling-2-Mini-Q8_0.gguf and
# `--spec-type draft-dspark --spec-draft-n-max 5` (unsloth: ~1.1-1.2x decode).
#
# Sampling follows the model card (temp 1.0, top-p 1.0, top-k off, min-p 0) —
# these are ALSO embedded in the GGUF (general.sampling.*), restated here so
# the run line is self-describing. Reasoning effort is per-request via
# chat_template_kwargs (template default: high).

let
  models = "/home/cjdell/Models/Inkling-2-Mini-GGUF";
  model = "${models}/Inkling-2-Mini-UD-Q4_K_XL.gguf";
  mmproj = "${models}/mmproj-F16.gguf";
  port = 8094; # engine slots: 8091 strata, 8092 coder, 8093 q36, 8094 inkling
  alias = "inkling-2-mini-ud-q4_k_xl";
in
{
  # strata-swap routing entry (consumed in ./strata.nix's swapConfig; the
  # shim's kind="llama" branch probes llama-server's /slots instead of
  # Strata's /v1/status — ./strata-swap.py).
  ai.swapEngines = [
    {
      id = alias;
      unit = "inkling-2-mini";
      port = port;
      vramMinMiB = 25000; # after the strata stop: weights+KV alone need ~27 GB
      kind = "llama";
    }
  ];

  # So gpu-mode stops/protects this unit with the rest of the llm lease.
  ai.strataEngineUnits = [ "inkling-2-mini" ];

  systemd.services."inkling-2-mini" = {
    description = "llama.cpp Vulkan server (Inkling-2-Mini UD-Q4_K_XL) on the R9700 — strata-swap lane";
    documentation = [ "https://huggingface.co/unsloth/Inkling-2-Mini-GGUF" ];
    after = [ "network.target" ];
    # Swap-only, like the strata partners: strata-swap starts it when a
    # request names it; NO wantedBy, so the boot default stays Strata.
    # Runs as root because /home/cjdell is 700 (the llama-log-viewer reason).

    # Pin to the R9700 and hide the RX 580 (AGENTS.md "GPU pinning"): the
    # trailing `!` makes the R9700 the only visible device, so --device
    # Vulkan0 cannot silently mean the console card.
    environment = {
      XDG_DATA_DIRS = "/run/opengl-driver/share";
      MESA_VK_DEVICE_SELECT = "1002:7551!";
      # Vulkan's default is 100 graph nodes per queue submit, and this arch is
      # DISPATCH-BOUND, not bandwidth-bound: one decoded token is ~7,650 kernel
      # launches and 66 % of the step time is ~3.6 us elementwise/copy kernels
      # (GGML_VK_PERF_LOGGER on 2026-11-23 — SiTU's scale/sigmoid/sqr/sqrt/tanh
      # and the loop's concat/cont/cpy/repeat, all separate dispatches). 100
      # nodes/submit therefore meant ~77 submits per token; batching them all
      # measured +3.9 % tg128 (34.38 -> 35.73 t/s) and +0.7 % pp512.
      GGML_VK_MAX_NODES_PER_SUBMIT = "10000";
    };

    unitConfig.ConditionPathExists = [
      model
      mmproj
    ];

    serviceConfig = {
      ExecStart = ''
        ${llamaCppPkgs.vulkan}/bin/llama-server \
          --model ${model} \
          --mmproj ${mmproj} \
          --device Vulkan0 \
          --n-gpu-layers 99 \
          --jinja \
          --ctx-size 524288 \
          --flash-attn on \
          --cache-type-k q8_0 --cache-type-v q8_0 \
          --batch-size 4096 --ubatch-size 1024 \
          --parallel 1 \
          --slots \
          --host 127.0.0.1 --port ${toString port} \
          --alias ${alias} \
          --temp 1.0 --top-p 1.0 --top-k 0 --min-p 0.0
      '';
      Restart = "on-failure";
      RestartSec = 5;
      TimeoutStopSec = 120;
    };
  };
}
