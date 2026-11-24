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
  # The serve layer with our monitor fixes (./inkling-metrics.diff): prefill
  # progress per slot + before the first engine line, and the request table's
  # decode rate (it read "-" for every request on this lane).  A copy of the
  # share tree with the diff applied and bin/strata-server re-pointed at it -
  # the engine binary is the package's, so this costs a file copy rather than
  # a HIP rebuild.  See ./strata-inkling-serve.nix.
  serve = pkgs.callPackage ./strata-inkling-serve.nix { inherit strataInkling; };
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
  share = "${serve}/share/strata";
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

  # What adopt.py's inkling branch writes for a GGUF build, by hand, plus the
  # conversation-parking contract (see inkling-conversation-park.diff).
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
        # 160K.  Measured on this card 2026-11-24 (fp16 KV, chunk 2048,
        # DSpark off), from live VRAM between two depths - not from an estimate:
        #   model + arena, no K/V      18,623 MiB
        #   a 20,394-token chat        22,084 MiB
        #   119,350 + 20,457 held      29,582 MiB
        # marginal cost = (29,582-22,084)/(119,350-20,394) = 0.0758 MiB/token
        # (~78 KB).  So 147456 needs 29,800 MiB and left 2.8 GiB idle - the
        # "3 GB on the table".  163840 needs 12,419 MiB of K/V -> ~31.0 GiB
        # used, ~1.6 GiB spare, which is the headroom the prefill scratch
        # wants.  176K would leave ~600 MiB (too tight); 200K+ needs the
        # smaller SQ-10 pack (10.5 GB) or parking on, since 32,624 MiB total
        # minus 18,623 of weights is ~165K tokens of K/V in all.
        "163840"
        # FP16, NOT FP8 (measured 2026-11-24 on this card, --bench, gen 128).
        # fp8 is a shallow-depth trick and a depth penalty: at a 512-token
        # prompt it is faster (95.1 vs 53.2 t/s) but from ~4K it loses, and by
        # the depth a real agent session sits at it is ~35% slower:
        #   @32768: fp8 37.8  fp16 48.5
        #   @65536: fp8 23.0  fp16 40.3
        #   @98304: fp8 22.6  fp16 34.6
        # The engine's own auto rule (fp8 only when free VRAM is short) would
        # have picked fp16 here too, and parking means only one slot's K/V is
        # ever resident, so fp16 fits with room.
        "--kv"
        "fp16"
        # The HIP dispatch guard allows 8192 for a >=36 CU block, but the
        # engine's default `--chunk` is 512 and that is what actually gates
        # prefill. Measured at 8192-token prompts: 512 -> 874 t/s,
        # 1024 -> 1137, 2048 -> 1348, 4096 -> 1346 (plateau). At 32768 the
        # same 2048 setting gives 1219 vs 738 at the default; at 65536, 1083
        # vs 640. Each chunk costs SWA ring positions (win 1024 + chunk), so
        # 2048 keeps the ring at 3072 positions.
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
      # DSpark OFF for now.  Measured on a CLEAN card 2026-11-24 with this line off, same engine build:
      #   397-token prompt   prefill  765 t/s   decode 63.6 t/s
      #   20,394-token prompt prefill 1380 t/s   decode 53.2 t/s   (64 tokens, 16.0 s)
      # The 0.2-11 tok/s decodes measured earlier the same day were NOT the drafter: they were orphan
      # engine processes holding 20+ GiB (a stop had left them behind, see ExecStopPost below), so the
      # live engine's experts were being read from host RAM - the GPU then sat at 100 % "busy", ~120 W
      # and 0 % memory activity, the docs/strata-hang.md spin signature.  DSpark was never A/B'd on a
      # clean card with enough output tokens (the 69.7 vs 0.2 figures came from 4-token answers and a
      # contaminated card).  Its documented upside is only +2-2.5 % decode, so it stays off until that
      # A/B is run cleanly; `drafting = "dspark"` is the one-line revert.
      drafting = "off";
      # TWO slots, for cache separation rather than throughput: a title/probe
      # call that continues nothing is routed to the *other* slot instead of
      # overwriting the agent's conversation where it sits (serve/inkling's
      # _inkling_route; upstream sent every non-continuing request to slot 0,
      # "a side request (20 tokens) replaced the cached chat (78361 tokens)",
      # 2026-11-24). The second slot is only a K/V allocation when it actually
      # runs something. A request that CONTINUES a busy slot's conversation now
      # waits for that slot instead of taking the other one (CONTINUATION_WAIT_S,
      # see ./inkling-conversation-park.diff): one conversation resident twice
      # is ~218K tokens of K/V against a ~178K budget, which is what made both
      # slots thrash.
      #
      # Conversation PARKING (engine-side: parks idle slots to pinned host RAM)
      # is OFF by default in this build.  The 400-800 s "reading the prompt"
      # stalls that motivated that were measured while orphan engines held the
      # card (see ExecStopPost below), so parking has NOT been shown to be slow
      # on a clean one - it restores in ~0.5 s for 16.7K.  STRATA_INK_PARK=1
      # turns it back on and it needs a clean re-test before it is default again;
      # the serve-side routing above is independent of it and stays on.
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
      # (NOT raised to cover the "expert arena 25.54 -> 24.84 GiB: only 27.75 GiB free" line - that is the engine's
      # own trunk+vision+drafter already resident when it sizes the arena, not another program: with the card
      # completely idle, amd-smi read 32,567 MiB free and the engine still reported the same 27.75 GiB
      # (measured 2026-11-24).  The arena is 24.84 GiB in normal operation.)
    }
  ];

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
        ${serve}/bin/strata-server --engine strata --config ${runConfig} \
          --host 127.0.0.1 --port ${toString port}
      '';
      Restart = "on-failure";
      RestartSec = 5;
      TimeoutStopSec = 120;
      # A stop/restart has left the ENGINE behind: systemd reported the unit
      # "Deactivated successfully" while strata-inkling --serve kept its
      # 20+ GiB, so the next engine started with no room, its experts went to
      # host RAM and decode collapsed to 0.2-11 tok/s (2026-11-24: two orphan
      # engines plus a stray bench held 31.9 of 32.6 GiB with 700 MiB free,
      # which read exactly like a broken drafter and cost a day of chasing).
      # The pattern names the FULL deployed argv (bin/ + the model path) on
      # purpose: a short one like 'strata-inkling --serve' also matches an
      # operator's `pgrep -af ...`/`grep` line, and the first version of this
      # killed the shell that ran the stop.  The `-` ignores "no match".
      ExecStopPost = "-${pkgs.procps}/bin/pkill -f 'bin/strata-inkling --serve --native /home/cjdell/Models/Inkling-2-Mini-GGUF'";
      # Engine watchdog aborts (#29) used to dump 32 GB cores on / here.
      LimitCORE = 0;
    };
  };
}
