{
  config,
  lib,
  pkgs,
  llamaCppPkgs,
  ...
}:

# Qwen3.8-27B on the R9700 — the 256K-context dense lane.
#
# Qwen3.8-27B is a dense 27B model (qwen35 arch, 21 blocks, hybrid:
# full_attention_interval=4 so only ~6 layers hold KV, 4 KV heads,
# 128 head dim, 131072 native context — 256K via --ctx-size). It is NOT a Flash-Next pack and NOT
# a qwen35moe MoE, so Strata cannot run it — this lane is stock llama.cpp
# (HIP/gfx1201), like the old Inkling lane before it moved to Strata.
#
# WHY 256K: the model's native context is 131072; 256K is a 2x extension
# (llama.cpp will warn but run it — the hybrid arch's KV is small). At 256K
# with UD-Q5_K_XL (20.2 GB weights) + q8_0 KV, the KV cache is ~2 x 6 full-
# attention layers x 4 heads x 128 dim x 262144 tokens x 1 byte (q8_0) =
# ~1.6 GB — fits comfortably in the remaining ~12 GB of VRAM alongside the
# weights. f16 KV would be ~3.2 GB, still fits but leaves less headroom for
# prefill scratch. q8_0 is the speed/memory sweet spot.
#
# WHY --kv-offload: the user wants multi-turn support with parking ctx in
# system RAM when switching conversations. llama.cpp has no built-in
# conversation parking (that is a Strata feature), but --kv-offload offloads
# the KV cache to pinned host RAM when the slot is idle, which is the
# closest equivalent: switching conversations parks the old conversation's
# KV in RAM and restores it on return. --cache-ram N (default 8 GB) keeps
# the prompt cache in RAM too. --cache-reuse 256 reuses KV across turns.
#
# WHY MTP: mtp-Qwen3.8-27B-Q4_0.gguf (1.37 GB) is on disk. MTP speculation
# gives ~20% decode speedup. --spec-draft-n-max 2 is the safe default.
#
# RUN LINE: llama-server with --slots (for the swap shim's /slots dialect),
# --kv-offload, --cache-ram 16384, --cache-reuse 256, --flash-attn,
# --cache-type-k q8_0 --cache-type-v q8_0, --ctx-size 262144, --parallel 1,
# --spec-type draft-mtp --spec-draft-n-max 2, --jinja, --jinja-chat-template,
# --host 127.0.0.1 --port 8095.
#
# The unit is swap-only (no wantedBy): strata-swap starts it on a `model`
# mismatch, like the other partners.

let
  models = "/home/cjdell/Models";
  model = "${models}/Qwen3.8-27B-UD-Q5_K_XL.gguf";
  mtp = "${models}/mtp-Qwen3.8-27B-Q4_0.gguf";
  port = 8095; # engine slots: 8091 strata, 8092 coder, 8093 q36, 8094 inkling, 8095 qwen27b
  alias = "qwen3.8-27b-ud-q5_k_xl";

  llama-server = llamaCppPkgs.rocm;

  # The mesa device-select layer hides the console GPU (RX 580) from this
  # process; the R9700 is the only HIP device. HIP_VISIBLE_DEVICES=0 pins it.
  env = {
    HIP_VISIBLE_DEVICES = "0";
  };

  runArgs = [
    "--host" "127.0.0.1"
    "--port" (toString port)
    "--model" model
    "--ctx-size" "262144"
    "--n-gpu-layers" "99"
    "--flash-attn" "on"
    "--cache-type-k" "q8_0"
    "--cache-type-v" "q8_0"
    "--kv-offload"
    "--cache-ram" "16384"
    "--cache-reuse" "256"
    "--parallel" "1"
    "--slots"
    "--jinja"
    "--spec-type" "draft-mtp"
    "--spec-draft-n-max" "2"
    "--spec-draft-model" mtp
    "--log-prompts-dir" "/home/cjdell/nixos-config/llama-logs"
  ];

  # The swap shim's kind "llama" dialect: /slots answers only once the model
  # is loaded; empty list = idle. --slots is required for this.
  swapEntry = {
    id = alias;
    unit = "qwen27b";
    port = port;
    vramMinMiB = 25000; # weights 20.2 GB + KV ~3 GB + prefill scratch ~5 GB
    kind = "llama";
  };

in
{
  ai.swapEngines = [ swapEntry ];

  systemd.services.qwen27b = {
    description = "llama.cpp HIP server (Qwen3.8-27B UD-Q5_K_XL, 256K ctx) on the R9700 — strata-swap lane";
    documentation = [
      "https://huggingface.co/unsloth/Qwen3.8-27B-GGUF"
    ];
    after = [ "network.target" ];
    # Swap-only, like the other partners: strata-swap starts it on a `model`
    # mismatch; NO wantedBy, so the boot default stays Strata.
    # Runs as root because /home/cjdell is 700.

    unitConfig.ConditionPathExists = [
      model
      mtp
    ];

    serviceConfig = {
      ExecStart = lib.concatStringsSep " " (
        [ "${llama-server}/bin/llama-server" ] ++ runArgs
      );
      Environment = lib.mapAttrsToList (k: v: "${k}=${v}") env;
      Restart = "on-failure";
      RestartSec = 5;
      TimeoutStopSec = 120;
      LimitCORE = 0;
    };
  };
}
