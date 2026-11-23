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
# VRAM: weights + KV + idle graphs, sized to the depth sessions ACTUALLY reach.
# Measured on this box's 32624 MiB (headless R9700, console is the RX 580),
# 2026-11-23, at -c 131072 / -b 1024 -ub 512 / q8_0 KV:
#
#   weights (UD-Q4_K_XL)      16800 MiB   all 48 visits GPU-resident (-ngl 99;
#                                         17.6 GB is why Q4_K_XL, not Q8_K_XL)
#   KV @ 131072 ctx, q8_0      2280 MiB   8 full-history CACHE layers (physical
#                                         5, 11, 17, 23 — the loop makes 11 and
#                                         17 into 3 cache layers each) x K,V x
#                                         8 kv-heads x 128 x 1.0625 B q8_0 =
#                                         17408 B/token; + 42.5 MiB fixed for
#                                         the 20 windowed (1024-cell) layers
#   mmproj F16 (vision)         640 MiB
#   graphs/slack              ~3200 MiB
#   --------------------------------------------------------------
#   idle                      22941 MiB used, 9683 free, GTT 530
#
# 128K is a deliberate sizing choice, not a model limit (1M native): live agent
# sessions here reach ~96K, and every 128K of reserved window costs 2.2 GB of KV
# — exactly the headroom the prefill scratch needs. At 384K (6.6 GB KV) a 53.6K
# prompt measured 431 t/s with 2.6-4.8 GB spilled to GTT; at 128K the same
# prompt measures **551 t/s**. The fleet's other 32 GB lanes sit at 40-65K for
# the same reason.
#
# THE PREFILL SCRATCH IS DEPTH-PROPORTIONAL — the thing to know about this lane.
# While a graph runs, the Vulkan attention working set grows with the tokens in
# it (~140-300 KB per token of depth: +7.7 GB at a 53.6K prompt, ~16 GB at 95K)
# and it is NOT a function of batch shape — `-b 512 -ub 512` measured
# byte-identical in speed AND residency to `-b 1024 -ub 512`. Whatever does not
# fit in free VRAM silently lands in GTT. Two reasons it grows with depth: the
# FA kernels materialise per-op scratch, and with a QUANTISED KV cache EVERY
# graph re-dequantises the WHOLE cache to f16 before attention (ggml-vulkan's
# `use_dequant_kv`: `k_quant && v_quant` -> a full-depth f16 copy, per global
# layer visit). That is why a ~700-token turn at 92K depth costs 28 s while the
# same turn shallow costs ~1 s. A/B'd 2026-11-23 and REJECTED as the cause:
# `q8_0/f16` (which makes kv_raw true and skips that copy) measured 21.77 t/s at
# d90000 against 21.85 for `q8_0/q8_0` — identical, so the dequant copy is not
# what costs the depth. It is the backend's attention path (see the HIP note
# below), not the cache layout.
#   * keep prompt prefixes stable so LCP reuse skips the re-read entirely;
#   * shrink -c if sessions get shallower: 2.2 GB of KV per 128K.
# -c sweep at the old 384K setting (same line, nothing else changed): 524288 ->
# 29717 used / 2907 free; 655360 -> 32562 / 62 (+0.9 GB GTT); 786432 -> 32533 /
# 91 (+4.6); 917504 -> 32564 / 60 (+8.3). All load; past ~600K the marginal KV
# itself goes to GTT. UD-IQ4_XS is 1.8 GiB smaller but measured identical in
# speed — AGENTS.md.
#
# PREFILL RATES — clean card, ONE server, 2026-11-23. The BACKEND matters more
# than any flag at depth, so both are listed (pp4096 except where noted):
#
#   depth        Vulkan        HIP (deployed)
#   d 0        1069 (pp512)    1012
#   d 3.5K      877 (live)     —
#   d 32K       505 (pp2048)   269
#   d 65K       —              170
#   d 90K        21.9          134
#   decode      34.2 @ d0      27 @ 32K, 25 @ 65K
#
# WHY HIP. Vulkan's flash-attention path falls off a cliff between 84K (106 t/s
# instantaneous, from a live 95K session log) and 88K (22 t/s) — and it is NOT
# memory or KV type: at d90000 `q8_0/q8_0` and `q8_0/f16` measured 21.85 vs
# 21.77 t/s, `GGML_VK_DISABLE_COOPMAT2` changed nothing (21.86), and the GPU sat
# at 48 % busy / 294 W peak while HIP does the same prompt at 97 % busy / 207 W.
# HIP's curve is smooth and stays >100 t/s across the whole 128K window. The
# price is shallow speed (269 vs 505 at 32K) — the right trade for a lane whose
# live sessions grow past 70K, because Vulkan's failure mode there is unusable
# (22 t/s) while HIP's is merely slower. Package: `llamaCppPkgs.rocm`, built
# with `rocmGpuTargets = "gfx1201"` in flake.nix (same llama.cpp pin as Vulkan;
# without that target ROCm has no compatible kernels for this card).
#
# BATCH SIZE: `-b 1024 -ub 512`, and `-ub 512` is a SHARP optimum on both
# backends — not a plateau. Re-swept on the HIP build 2026-11-23 (pp2048, -r 2,
# q8_0 KV, GGML_CUDA_DISABLE_GRAPHS=1) — full 49 152-token cold prefill /
# pp2048 @d65K / pp2048 @d90K:
#   1024/512 (this)   329.8 / 171.7 / 134.3
#   2048/512            —   / 171.9 /  —      (-b is irrelevant, as before)
#   2048/1024         331.8 / 171.5 / TIMEOUT (>600 s)
#   16384/2048          —   / TIMEOUT / —
#    2048/384         284.4 /  —    / TIMEOUT
#    2048/288         239.9 /  —    / TIMEOUT
# `-ub 1024` measures +10 % (748 vs 679) on a shallow 2K prompt and buys nothing
# on a real prefill, so that gain is an artefact; every value but 512 collapses
# at depth. Community RDNA4 advice points the other way (llama.cpp discussion
# #21043: `-ub 2048` = +29 % prefill, `-b 16384 -ub 2048` = +48 %, dead band at
# 65-256) and the usual R9700 configs are 2048/512 or 2048/1024 — none of it
# transfers to `inkling2_loop`. Vulkan-era numbers kept for the same reason:
# -ub 1024 at 53.6K = 128 vs 431 t/s, -ub 256 = 481 @ 32K, -b 4096 hangs
# llama-bench, q4_0 KV = 471 @ 32K. And -c 393216 vs 131072 on that 53.6K
# prompt: 431 vs 551 t/s — the reserved-but-unused KV was the scratch's headroom.
#
# WHY IT STILL DECAYS WITH DEPTH (and why the Qwen3.8 lane does not): upstream's
# best published Inkling figure on an R9700 is 893 t/s at 16K, also decaying, so
# "1000 t/s across a long context" is not reachable on llama.cpp for
# `inkling2_loop`. Architecturally this is a LOOPED transformer (24 physical
# layers, 6-17 run 3x = 48 visits per token, 8-of-128 MoE, mostly
# sliding-window attention) paying a per-visit cost in a generic backend; the
# Qwen3.8-Flash-Next lane is flat because most of its layers are
# gated-delta-net (linear attention: constant state, no depth term) and Strata
# has hand-fused kernels for them. Full comparison in AGENTS.md.
#
# --parallel 1 (llama-server's default): the whole pool to one conversation;
# a second client queues instead of halving both streams (the strata-batch
# lesson, docs/strata-batching.md). No DSpark drafter: mainline support is
# still an open PR (ggml-org/llama.cpp#32218).
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
    description = "llama.cpp HIP (ROCm) server (Inkling-2-Mini UD-Q4_K_XL) on the R9700 — strata-swap lane";
    documentation = [ "https://huggingface.co/unsloth/Inkling-2-Mini-GGUF" ];
    after = [ "network.target" ];
    # Swap-only, like the strata partners: strata-swap starts it when a
    # request names it; NO wantedBy, so the boot default stays Strata.
    # Runs as root because /home/cjdell is 700 (the llama-log-viewer reason).

    # HIP, not Vulkan — Vulkan's FA path drops off a cliff between 84K and 88K
    # depth (106 -> 22 t/s) with the GPU only 48 % busy, and no KV type or
    # coopmat2 setting changes it; HIP runs the same 90K prompt at 134 t/s at
    # 97 % busy. Curve and A/B evidence in the header above and AGENTS.md.
    # Only the R9700 is HIP-visible (gfx803 is not supported by ROCm 7), so
    # device 0 is always the dGPU and the console RX 580 cannot be picked.
    environment = {
      HIP_VISIBLE_DEVICES = "0";
      # ROCm 7.2.3's hipGraphExecUpdate SEGVs inside VirtualGPU::submitKernel-
      # Internal when ggml-hip captures/updates a graph (crash 2026-11-23
      # 22:07:50, stack: ggml_cuda_graph_launch_chunk -> hipGraphExecUpdate ->
      # amd::roc::VirtualGPU::submitKernelInternal). Graphs are a launch-overhead
      # optimisation only, so the documented escape hatch is to turn them off
      # until ROCm fixes it — measure the decode cost before re-enabling.
      GGML_CUDA_DISABLE_GRAPHS = "1";
    };

    unitConfig.ConditionPathExists = [
      model
      mmproj
    ];

    serviceConfig = {
      ExecStart = ''
        ${llamaCppPkgs.rocm}/bin/llama-server \
          --model ${model} \
          --mmproj ${mmproj} \
          --device ROCm0 \
          --n-gpu-layers 99 \
          --jinja \
          --ctx-size 131072 \
          --flash-attn on \
          --cache-type-k q8_0 --cache-type-v q8_0 \
          --batch-size 1024 --ubatch-size 512 \
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
