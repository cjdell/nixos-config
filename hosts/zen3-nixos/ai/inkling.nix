{
  config,
  lib,
  pkgs,
  ...
}:

# Inkling-2-Mini on the R9700 — the STRATA swap lane.
#
# Thinking Machines' Inkling 2 Mini (released 2026-11-20, Apache 2.0): 26.4B
# MoE / 3.4B active (5.4B effective — layers 6-17 of 24 run THREE times with
# shared weights, so 48 layer-visits per token), 8 of 128 experts per layer,
# hybrid local/global attention (4 global layers of 24, sliding window 1024
# for the rest), natively multimodal. The GGML arch is `inkling2_loop`.
#
# WHY STRATA NOW (this changed 2026-11-22/24 — the lane used to be llama.cpp
# because Strata could not run this arch at all): Strata 0.2.19 shipped
# `strata-inkling`, a dedicated shape engine for exactly this model
# (engine/src/inkling2 + a first-class HIP backend listing gfx1200/gfx1201),
# with native DSpark drafting (the thing llama.cpp still lacks — mainline PR
# ggml-org/llama.cpp#32218 open), 1..64 continuous batching, and direct
# GGUF_RAW loading of the Unsloth file already on disk (both GGUF layouts
# accepted since 0.2.21). 0.2.21 (2026-11-24) is what we run: it fixes the
# long-context/small-card decode collapses reported on the pack repo
# ("RTX 5070 12 GB SQ-10: 68 instead of 12.5 tok/s"). Reference points:
# upstream's own R9700 row (SQ-10): 99-106 t/s decode, 3,982 t/s prefill;
# the community RDNA4 benchmark bundled in that tree (RX 9070 XT 16 GB,
# SQ-10, 0.2.20): 62 t/s short / 44 t/s at 16K depth, 2.3K t/s prefill,
# 13.2 GiB VRAM — versus this card's llama.cpp lane at 33-36 t/s decode and
# 551 t/s on a live 53.6K prefill (see git history of this file, the
# 2026-11-23 measurements).
#
# WHY A SEPARATE 0.2.21 BUILD AND NOT A BUMP OF ./strata.nix: our own upstream
# issue #6420 — the layers 18-22 prefill spin that forced the revert to
# 0.2.13.1 (docs/strata-prefill-stall-2026-11-20.md) — is STILL OPEN
# (2026-11-24, no maintainer reply). The Flash-Next engine on 0.1.67 would
# re-expose every agent session here to it. strata-inkling is a separate
# binary and a separate serve instance, so this lane runs the new tree and
# ./strata.nix keeps running the proven one; flip ./strata.nix's pin to
# 0.2.21 only after #6420 is fixed or a soak says otherwise.
#
# HOW IT JOINS THE SWAP: unchanged from the llama era — ai.swapEngines entry,
# id `inkling-2-mini-ud-q4_k_xl` on :8094, and strata-swap routes by `model`
# (drain -> stop live -> wait VRAM -> start this unit -> wait /v1/status
# loaded:true -> forward). kind now defaults to "strata": the 0.2.21 serve
# layer answers /v1-status style exactly like the main lane (loaded,
# activity.in_flight), so the shim needs nothing special and gpu-mode's
# lease list (ai.strataEngineUnits) is unchanged — same unit name.
#
# THE FILES: the GGUF stays where scripts/fetch-inkling-2-mini.sh put it
# (Mainline_Support layout, = Strata's ALT_GGUF pin, so both engines read
# the same bytes). scripts/fetch-inkling-strata.sh adds the strata-side
# companions, all size+sha pinned: tokenizer.json + chat_template.jinja
# (serve's chat dialect — the unit's ExecStartPre turns them into
# tokenizer/vocab.json once via the package's tools/inkling_tokenizer.py),
# Inkling-2-Mini-Vision.strata (the engine reads images ONLY from this
# shard — the mmproj-F16.gguf beside the GGUF is llama.cpp's projector and
# stays that way), mtp.safetensors (Thinking Machines' BF16 DSpark drafter,
# which a dspark_f32_widen=1 engine drafts 3-7x/step from), and
# dspark-Inkling-2-Mini-Q8_0.gguf (Unsloth's Q8_0 drafter at the pinned
# pre-re-upload commit — serve/inkling_kind.py's fit_dspark() falls back to
# it automatically if the engine cannot read the BF16 one). ConditionPath-
# Exists keeps the unit down until the fetch ran, as everywhere here.
#
# RUN LINE = what `strata launch` writes for this build (adopt.py) + the
# community RDNA4 bench's shape: --native <gguf> --max-context 131072 --kv
# fp8 (HIP supports fp16/fp8 only; fp8 = 16 KiB/token on the 8 global
# visits, ~2.2 GB at 128K) --vision <Vision.strata> --dspark <mtp>. With
# UD-Q4_K_XL the fit table puts 15.80 GB expert bodies + a 2.45 GB BF16
# trunk on the card — all 48 visits GPU-resident at ~21 GB + KV, comfortably
# on the 32 GiB card; no --vram-experts-gb/--ram-experts-gb override, the
# planner on a 32 GiB card has nothing to spill (the 9070 XT bench NEEDED
# them on 16 GiB; we do not). Drafting is pinned "dspark" instead of the
# "auto" default: "auto" runs a ~3 min measured probe (1.10x gain gate) at
# the first start of a placement, and we want the deterministic thing here
# (0.2.21 also added a startup drafter probe — every first start of a new
# setup costs ~3 min extra; that is one-time).
#
# A/B against the old llama lane without reverting the unit (stop this unit
# first — two ~17 GB models do not share 32 GB; and grep pgrep for a second
# llama-server/strata before believing any GTT number, AGENTS.md): the old
# run line is in this file's git history (llamaCppPkgs.rocm, -b 1024 -ub 512,
# q8_0 KV, 33-36 t/s decode / 551 t/s live 53.6K prefill, 2026-11-23).

let
  strataInkling = pkgs.callPackage ./strata-inkling-package.nix { };
  # The same store-built ROCm 10.0.0 runtime ./strata.nix puts first in
  # LD_LIBRARY_PATH (its header explains why it is not nixpkgs'). Verify a
  # boot with: sudo cat /proc/$(pgrep -f 'strata-inkling --serve')/maps | grep -c rocm10
  rocm10 = pkgs.callPackage ./rocm10-runtime.nix { };

  models = "/home/cjdell/Models/Inkling-2-Mini-GGUF";
  model = "${models}/Inkling-2-Mini-UD-Q4_K_XL.gguf";
  vision = "${models}/Inkling-2-Mini-Vision.strata";
  drafter = "${models}/mtp.safetensors";
  drafterAlt = "${models}/dspark-Inkling-2-Mini-Q8_0.gguf";
  tokenizerDir = "${models}/tokenizer";
  share = "${strataInkling}/share/strata";
  port = 8094; # engine slots: 8091 strata, 8092 coder, 8093 q36, 8094 inkling
  alias = "inkling-2-mini-ud-q4_k_xl";

  # argv: <out_dir> <tokenizer.json> <chat_template.jinja>. A file rather
  # than an inline `-c` so the ExecStartPre line stays one shell word of
  # Nix-interpolated paths (see the ExecStartPre comment below).
  tokenizerScript = pkgs.writeText "inkling-tokenizer.py" ''
    import sys
    sys.path.insert(0, ${builtins.toJSON share} + "/tools")
    import inkling_tokenizer
    out, tj, ct = sys.argv[1:4]
    print(inkling_tokenizer.convert_files(tj, ct, out))
  '';

  # What adopt.py's inkling branch writes for a GGUF build, by hand. No
  # `parallel` >1 and no expert caps: solo slot, everything on the card.
  runConfig = pkgs.writeText "strata-inkling.json" (
    builtins.toJSON {
      exe = "${strataInkling}/bin/strata-inkling";
      backend = "hip";
      arch = "inkling2_loop"; # serve routes the whole Inkling dialect by this (serve/inkling_kind.py)
      cwd = share;
      args = [
        "--native"
        model
        "--max-context"
        "131072"
        # FP16, NOT FP8 (measured 2026-11-24 on this card, --bench, gen 128).
        # fp8 is a shallow-depth trick and a depth penalty: at a 512-token
        # prompt it is faster (95.1 vs 53.2 t/s) but from ~4K it loses, and by
        # the depth a real agent session sits at it is ~35% slower:
        #   @32768: fp8 37.8  fp16 48.5
        #   @65536: fp8 23.0  fp16 40.3
        #   @98304: fp8 22.6  fp16 34.6
        # The engine's own auto rule (fp8 only when free VRAM is short) would
        # have picked fp16 here too; we forced fp8 for a capacity reason that
        # does not exist on a 32 GiB card with all experts resident.
        "--kv"
        "fp16"
        # The HIP dispatch guard allows 8192 for a >=36 CU block, but the
        # engine's default `--chunk` is 512 and that is what actually gates
        # prefill. Measured at 8192-token prompts: 512 -> 874 t/s,
        # 1024 -> 1137, 2048 -> 1348, 4096 -> 1346 (plateau). At 32768 the
        # same 2048 setting gives 1219 vs 738 at the default; at 65536, 1083
        # vs 640. Each chunk costs SWA ring positions (win 1024 + chunk), so
        # 2048 keeps the ring at 3072 of the 131072 context.
        "--chunk"
        "2048"
        "--vision"
        vision
        "--dspark"
        drafter
      ];
      tokenizer = tokenizerDir;
      model_name = alias;
      log = "/var/lib/inkling/inkling.log";
      lib_dirs = [ "${rocm10}/lib" ];
      # Same shim path as the main lane: forwarded agent traffic keeps the
      # public Host header, so the serve DNS-rebinding guard needs the names.
      allowed_hosts = [
        "strata.ai.chrisdell.info"
        "llama.ai.chrisdell.info"
        "llm.ai.chrisdell.info"
      ];
      drafting = "dspark";
      # TWO slots, and the second one exists for the cache, not throughput.
      # With one slot the serve layer says it out loud (2026-11-24, live):
      #   "a side request (20 tokens) replaced the cached chat (78361 tokens);
      #    --parallel 2 keeps it"
      # i.e. every title/probe/classification call evicted the agent's 78-94K
      # conversation, and the next real turn re-read the whole thing from token
      # 0 (~150-200 s). With two slots serve/inkling's _inkling_route sends a
      # short request that continues nothing to the *other* slot and leaves the
      # conversation where it is. A lone request still takes the solo path
      # (GEN, slot 0, DSpark drafts), so single-stream speed is unchanged; the
      # cost is a second KV/SWA pool. Measured at 4096 tokens: par2 41.3/slot
      # vs par1 56.1, i.e. only when two requests really run together.
      parallel = 2;
      env = {
        HIP_VISIBLE_DEVICES = "0"; # only the R9700 is HIP-visible (gfx803 is out of ROCm)
      };
      before_load = "${pkgs.systemd}/bin/systemctl stop sd-server";
    }
  );
in
{
  # strata-swap routing entry (consumed in ./strata.nix's swapConfig). The
  # kind is now the default "strata": this lane's serve layer answers
  # /v1/status loaded/in_flight like the main lane.
  ai.swapEngines = [
    {
      id = alias;
      unit = "inkling-2-mini";
      port = port;
      vramMinMiB = 25000; # after the strata stop: experts+trunk+KV+drafter want ~23 GiB free
    }
  ];

  # So gpu-mode stops/protects this unit with the rest of the llm lease.
  ai.strataEngineUnits = [ "inkling-2-mini" ];

  systemd.services."inkling-2-mini" = {
    description = "Strata strata-inkling 0.2.21 server (Inkling-2-Mini UD-Q4_K_XL, DSpark) on the R9700 — strata-swap lane";
    documentation = [
      "https://huggingface.co/strata-engine/Inkling-2-Mini-Strata"
      "https://github.com/Niko1221/Strata/releases/tag/v0.2.21"
    ];
    after = [ "network.target" ];
    # Swap-only, like the strata partners: strata-swap starts it when a
    # request names it; NO wantedBy, so the boot default stays Strata.
    # Runs as root because /home/cjdell is 700 (the llama-log-viewer reason).

    unitConfig.ConditionPathExists = [
      model
      vision
      drafter
      "${models}/tokenizer.json"
      "${models}/chat_template.jinja"
      drafterAlt
    ];

    serviceConfig = {
      # Turn the pinned tokenizer.json + chat_template.jinja into the
      # tokenizer/vocab.json dir (what serve and adopt.py check), once.
      # tools/inkling_tokenizer.py imports stdlib only on this path.
      #
      # The paths go in as argv, not interpolated into a `bash -c '...'`:
      # inside a Nix indented string `'''` writes TWO quotes, so the inline
      # form produced `bash -c ''` plus three loose lines, which systemd
      # rejected ("Missing '=', ignoring line") and silently dropped — the
      # tokenizer step then never ran on a fresh model directory.
      ExecStartPre = pkgs.writeShellScript "inkling-tokenizer" ''
        set -eu
        test -e ${tokenizerDir}/vocab.json && exit 0
        exec ${pkgs.python3}/bin/python3 -B ${tokenizerScript} \
          ${tokenizerDir} ${models}/tokenizer.json ${models}/chat_template.jinja
      '';
      StateDirectory = "inkling";
      ExecStart = ''
        ${strataInkling}/bin/strata-server --engine strata --config ${runConfig} \
          --host 127.0.0.1 --port ${toString port}
      '';
      Restart = "on-failure";
      RestartSec = 5;
      TimeoutStopSec = 120;
      # Engine watchdog aborts (#29) used to dump 32 GB cores on / here.
      LimitCORE = 0;
    };
  };
}
