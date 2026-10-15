{
  config,
  lib,
  pkgs,
  ...
}:

# Strata on the R9700 (HIP/gfx1201): the Qwen3.8-Flash-Next experiment that
# replaces llama-swap. The llama-swap import in ./default.nix is commented
# out while this runs - both want the R9700's VRAM and tens of GB of RAM, and
# the whole point of Strata is to run a model llama.cpp could not fit.
#
# The engine + serve layer are packaged by ./strata-package.nix. Model data
# stays OUT of the store and is prepared ONCE by hand before this unit will
# start. We run the *highest* GSQ-RCO quant, IQ3_S (3.50 bpw non-uniform),
# up from IQ3_XXS (3.00 bpw) as of 2026-10-06. Only shard 1 differs between
# the two: shard 2 is the single per_layer_token_embd (PLE) table and is
# byte-identical across every GSQ-RCO quant (LFS sha256 316b46f3…), so it is
# hardlinked beside the IQ3_S shard below and read from disk either way.
# The PLE table is 26.82 GiB; shard 1 grows 43.81 -> 51.05 GiB, i.e. ~+7 GiB
# of routed-expert bytes that live in RAM (experts ~40 -> ~47 GiB). Unsloth's
# UD-* files are a different (packable, but larger) family - see docs/strata.md:
#
#   1. the two GGUF shards are in ggufDir, from
#      https://huggingface.co/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF
#      (shard 1 = experts/dense, shard 2 = the per_layer_token_embd table).
#      Because the pack tools need numpy + the pinned llama.cpp gguf-py, run
#      them with the engine's own python and STRATA_GGUF_PY:
#
#   PY=$(grep -o '/nix/store/[^ ]*-python3[^ ]*/bin/python3' ${strata}/bin/strata-server)
#   export STRATA_GGUF_PY=<llama.cpp-src>/gguf-py   # the pinned rev
#   cd ${strata}/share/strata/tools
#   # 2. the pack (index + dense tensors + tokenizer, ~1.5 GB):
#   $PY iq_pack.py --gguf ${nativeGguf} --out ${packDir}
#   # 3. the MTP draft runtime (~6 GB; the GSQ-RCO GGUF ships NO MTP head,
#   #    so the 31 mtp.* tensors always come from the BF16 checkpoint):
#   $PY mtp_fetch.py fetch --out ${modelDir}/mtp
#   $PY mtp_pack.py --src ${modelDir}/mtp --experts q2_0 \
#     --out ${modelDir}/mtp/mtp-q2_0.gguf
#   $PY mtp_rt.py --gguf ${modelDir}/mtp/mtp-q2_0.gguf --out ${mtpDir}
#   cp ${strata}/share/strata/data/draft_vocab.bin ${mtpDir}/   # cjk subset
#
# nginx: owns the "/" location on the IP vhost (llama-swap's old root) and a
# public strata.ai.chrisdell.info vhost.
#
# Two packs, one switch. `config.ai.strataModel` (default "iq3s", defined in
# ./default.nix) picks which GGUF/pack pair and which per-model engine args this
# unit uses; everything else (MTP runtime, expert profile, context, KV policy,
# nginx, the config JSON) is shared. The second pack is Unsloth's UD-IQ4_XS -
# 93.7 GB in three shards instead of 78 GB in two:
#
#   scripts/fetch-strata-udiq4xs.sh    # 3 shards, size + sha256 verified
#   scripts/repack-strata-udiq4xs.sh   # iq_pack.py --compat-bf16 (REQUIRED here)
#
# Its experts are 59.5 GB (55.4 GiB) against IQ3_S's 51.05 GB, so it needs
# --resident-budget-gib (see models.ud-iq4-xs below) and it costs GPU expert
# cache: the same 24.87 GiB holds ~11,000 of its experts instead of 13,104, so
# long-context decode drops (measured reasoning for docs/strata.md: ~33-37 tok/s
# at 255K vs 41). 262144 ctx itself is unaffected - the int8 KV is 13.7 KB/token
# and quant-independent. Switch only when that trade is wanted; the unit will not
# start a pack that has not been prepared (ConditionPathExists).

let
  strata = pkgs.callPackage ./strata-package.nix { };
  # The ROCm 10.0.0 runtime the engine loads instead of nixpkgs' 7.2.3; see
  # ./rocm10-runtime.nix for why it is not nixpkgs and how it is fetched.
  rocm10 = pkgs.callPackage ./rocm10-runtime.nix { };

  # Model layout. The GGUFs stay where they were downloaded (~/Models); only
  # the hand-prepared pack and MTP runtime live under modelDir.
  modelDir = "/home/cjdell/Strata";
  mtpDir = "${modelDir}/mtp/rt";

  # One entry per prepared pack; config.ai.strataModel (./default.nix) picks one.
  #   pleGguf    the shard holding the 26.82 GiB per_layer_token_embd table,
  #              passed as --ple-gguf; null = let the engine find it itself
  #              (generate.cpp:2209-2212 scans --native's shard set), which is
  #              what setup.py:5351 does for anything with more than 2 shards.
  #   extraArgs  per-model engine args on top of the shared set below.
  models = {
    # GSQ-RCO IQ3_S (3.50 bpw), two shards: shard 1 experts/dense, shard 2 the
    # PLE table (byte-identical across every GSQ-RCO quant, hardlinked).
    iq3s = {
      ggufDir = "/home/cjdell/Models/Qwen3.8-Flash-Next-GSQ-RCO-GGUF";
      packDir = "${modelDir}/pack/iq3s";
      nativeGguf = "/home/cjdell/Models/Qwen3.8-Flash-Next-GSQ-RCO-GGUF/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-00001-of-00002.gguf";
      pleGguf = "/home/cjdell/Models/Qwen3.8-Flash-Next-GSQ-RCO-GGUF/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-00002-of-00002.gguf";
      modelName = "qwen3.8-flash-next-iq3s";
      extraArgs = [ ];
    };

    # Unsloth UD-IQ4_XS (~4-bit Unsloth Dynamic), three shards. Each shard is
    # its own GGUF container: shard 1 is metadata only (0 tensors), shard 2
    # carries 373 tensors incl. the PLE table (IQ4_XS, same 26.82 GiB as GSQ's
    # shard 2), shard 3 the rest. --native is shard 1, like setup.py's shards[0].
    #
    # --resident-budget-gib 55 = setup.py's own recommendation for this box
    # (resident_budget_gib, setup.py:1515-1521: RAM 94 GiB - UNSLOTH_RAM_LEFT_GB
    # 24 - ceil(KV streamed to RAM ~3), capped at int(arena_gb 59.5 / 1.0737) =
    # 55): every expert in RAM, no SSD expert tier. That is +8.6 GiB over the
    # IQ3_S engine's 46.84 GiB of resident experts, leaving ~24 GiB free.
    # Without the flag the engine would try to hold all 55.4 GiB in its own
    # arena and the box OOMs; the flag is what makes the pack runnable here.
    ud-iq4-xs = {
      ggufDir = "/home/cjdell/Models/Qwen3.8-Flash-Next-UD-IQ4_XS-GGUF";
      packDir = "${modelDir}/pack/ud-iq4-xs";
      nativeGguf = "/home/cjdell/Models/Qwen3.8-Flash-Next-UD-IQ4_XS-GGUF/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf";
      pleGguf = null;
      modelName = "qwen3.8-flash-next-ud-iq4-xs";
      extraArgs = [
        "--resident-budget-gib"
        "55"
      ];
    };
  };

  model = config.ai.strataModel;
  m = models.${model};

  # The profile ships in the repo; the copy in the store is fine (the engine
  # only reads it).
  expertProfile = "${strata}/share/strata/data/expert-profile.bin";

  # 393216 = 1.5x the model's native 262144 window, raised from it on
  # 2026-10-15 because live traffic reached 211,459 tokens (81% of 256K).
  # Measured ceilings for this box (94 GB RAM, 32 GB R9700) are in
  # docs/strata.md.  Two things make the step up cheap here:
  #   * VRAM cost is ZERO. With --kv-resident 32768 only 32768 cells per QSA
  #     layer live in VRAM whatever --max-context is (the log line is
  #     "KV streaming: 32768 of 262144 cells per QSA layer in VRAM, the K/V in
  #     3.09 GiB of pinned RAM"), and the expert cache is sized off *free*
  #     VRAM, so a bigger context neither needs VRAM nor steals expert slots.
  #   * the int8 KV is allocated up front at max-context and lives in host
  #     RAM: 12 QSA layers x 1056 B = 12,672 B/token, so 3.09 GiB at 262144 ->
  #     4.64 GiB here (+1.55). Box-used goes ~58.5 -> ~60 GiB of 94. (The
  #     13.7 KB/token figure quoted in docs/strata.md counts the draft layer;
  #     12,672 B/token is what reproduces the engine's own 3.09 GiB.)
  # What it DOES cost: YaRN. The GGUF carries qwen4exp.context_length and NO
  # rope.scaling.type, and the engine's default is "the model file's rope keys,
  # else none" - so raising --max-context alone is raw 1.5x *extrapolation*
  # with no warning. The --rope-scaling yarn / --rope-scale 1.5 pair in
  # engineArgs below is MANDATORY, not tuning (--yarn-orig-ctx already defaults
  # to 262144). YaRN rescales every position, so it changes the 0-262144 region
  # we run 100% of traffic in, and "K in the cache is post-RoPE, so one run one
  # scaling" - it is fixed at startup and no A/B within a run is possible.
  # Prefill falls off with depth (measured on IQ3_S: 1393 t/s at 121K, 1184 at
  # 255K, 728 at 486K, 376 at 931K; ingest ~ depth^1.75), which INTERPOLATES to
  # ~870 t/s / ~7.4 min for a full fresh 384K prompt - unmeasured here, and it
  # only applies to prompts that actually go past 262144, never to the 60-210K
  # requests we actually serve. 524288 was rejected: 2x YaRN and ~11 min.
  context = 393216;

  # Mirrors setup.py's args for the 2-shard native IQ3_XXS pack (setup.py:4224),
  # with --kv int8 and KV streaming (--kv-resident) for the long context.
  # --ple-gguf is the shard holding the per_layer_token_embd table (shard 2).
  engineArgs = [
    "--pack"
    m.packDir
    "--native"
    m.nativeGguf
  ]
  ++ lib.optionals (m.pleGguf != null) [
    "--ple-gguf"
    m.pleGguf
  ]
  ++ [
    "--expert-profile"
    expertProfile
    "--expert-cache"
    "auto"
    "--prefill"
    "auto"
    "--spec"
    "4"
    "--spec-min-p"
    "0.5"
    "--mtp"
    mtpDir
    "--max-context"
    (toString context)
    # Required by the 393216 above - see the comment there. The engine reads
    # rope scaling from the model file first and this GGUF declares none, so
    # without these two flags the extra 131072 tokens are pure extrapolation.
    # Confirm it engaged in /var/lib/strata/strata.log:
    #   "rope scaling yarn, factor 1.5 (freq_scale ..., mscale ...), --max-context 393216 against a trained context of 262144"
    "--rope-scaling"
    "yarn"
    "--rope-scale"
    "1.5"
    "--kv"
    "int8"
    "--kv-resident"
    "32768"
    # ---- parked conversations (the multi-agent cache) --------------------
    # A chat or an agent resends its whole conversation on every turn.  By
    # default the engine keeps exactly ONE live session, so when an agent and
    # its subagents alternate requests they throw each other's KV away and
    # every turn re-reads the whole prompt from token 0.  Observed here before
    # this change: a 92,571-token prompt read at ~1.6K tok/s = ~56 s for a turn
    # that should have read a few hundred tokens, and the engine's own request
    # log showed reused=0 on every request that followed a different
    # conversation (consecutive turns of the same one reused 68-76K of ~75-85K).
    # Parking keeps up to `slots` independent conversations in host RAM (their
    # K/V pages + the ~118 MB/turn checkpoints) and restores the one a request
    # continues.  Matching is by exact token/image prefix only - no client
    # session id - so it is transparent to Pi and its subagents.  It costs host
    # RAM, not VRAM, and the cache slot is a switch-time decision: it degrades
    # to a fresh read, never a failure.
    #
    # Sizing for this box (94 GiB RAM, int8 KV 12,672 B/token, but a PARKED
    # conversation costs ~15-18 KB/token - measured from two live
    # "restored N tokens (live)" deltas, 1.2-1.4x the raw KV because it also
    # carries the GDN/SSM state - PLUS a per-conversation snapshot term that
    # peaked at 3.68 GiB.  So one FULL-LENGTH 393216 conversation is
    # ~5.7 GiB + ~3.7 GiB = ~9.4 GiB, and the old 12288 budget (which live
    # traffic had filled exactly: max bytes=12,852,981,612, evictions=100)
    # would then hold one max-length conversation and nothing else - i.e. it
    # stops working at the moment an agent and its subagent both need a slot.
    # 16 GiB keeps two of them parkable.  Past the budget the
    # least-recently-used conversation is evicted, so this is a cap, not a
    # reservation.  `--conversation-cache-min-free-mib` (default 2560) is the
    # RAM floor: parking is skipped when there is no room.
    "--conversation-cache-mib"
    "16384"
    "--conversation-cache-slots"
    "12"
    # Only park conversations worth a slot; one-shot probes / titles /
    # classification calls are cheap to re-read and must not evict a long
    # agent conversation (the log line is "skip parking (N tokens, below the M
    # minimum)").  2048 also skips the root-only checkpoint of a tiny request.
    "--conversation-cache-min-tokens"
    "2048"
  ]
  ++ m.extraArgs;

  # The run config serve/server.py reads: the engine binary (the Nix build),
  # its args, and the tokenizer. Kept read-only in the store for now; edit
  # this file and rebuild to change engine args (the web Settings view would
  # need a writable copy in /var/lib/strata instead).
  configFile = pkgs.writeText "strata-${model}.json" (
    builtins.toJSON {
      exe = "${strata}/bin/strata";
      args = engineArgs;
      cwd = "/var/lib/strata";
      tokenizer = "${m.packDir}/tokenizer";
      model_name = m.modelName;
      log = "/var/lib/strata/strata.log";
      # nginx proxies with the client's original Host header, and the serve
      # layer refuses any name it was not told about (DNS-rebinding guard) -
      # without this the public vhosts 403. 192.168.49.50 already answers.
      allowed_hosts = [
        "strata.ai.chrisdell.info"
        "llama.ai.chrisdell.info" # old llama-swap UI name, now a Strata alias
        "llm.ai.chrisdell.info" # old OpenAI-compatible name, now Strata
      ];
      # The engine is a HIP build (only gfx1201 kernels). Since the 5950X CPU
      # swap there is no iGPU at all, and amd-smi lists exactly one HIP device:
      # the R9700 (GPU 0, UUID 47ff7551-…; BDF 09:00.0 now, 03:00.0 before —
      # match by UUID, not BDF). HIP_VISIBLE_DEVICES=0 pins that one.
      backend = "hip";
      # ROCm 10.0.0 (TheRock) runtime, fetched into the store by
      # ./rocm10-runtime.nix. serve/server.py's child_env() PREPENDS lib_dirs
      # to the engine's LD_LIBRARY_PATH, which overrides the Nix build's RUNPATH
      # to nixpkgs' ROCm 7.2.3 - so the same binary loads the ROCm 10
      # libamdhip64/hsa-runtime. This is the fix for the #879 poisoned-context
      # class: same binary, same source, runtime only = 0 fires in 1911 requests
      # (vs 2/1399 on 7.2.3 the same day; the ROCm 7.2.1 r9700 libs fire again).
      # docs/strata-degeneration.md, docs/strata-maintainer-report.md.
      # Until 2026-10-14 this was /opt/rocm-10.0/lib laid down by hand by
      # scripts/setup-rocm10-libs.sh. child_env() silently DROPS a missing dir,
      # so that needed an ExecStartPre `test -e` to stop a silent fall back to
      # the buggy 7.2.3; a store path cannot be missing, so the guard is gone.
      lib_dirs = [ "${rocm10}/lib" ];
      env.HIP_VISIBLE_DEVICES = "0";
      # Local #879 instrumentation (see strata-package.nix): when a window's logits come
      # out non-finite, dump the first non-finite (layer, row, col, raw bits) per
      # grouped-expert stage. Tracks down whether our fire is the same
      # 0x7FFFFFFF routed-expert data-path garbage the CUDA reporter saw - the thing
      # upstream still cannot reproduce (#879 open; 1,870 R9700 requests) and has asked us
      # for capture data. Since 0.1.43 this is opt-in in the code too: the flags are only
      # allocated with this set to 1, because every audit probe is an extra node in the
      # captured verify graph (~10 per layer) and 0.1.43 measured that cost while removing
      # nodes for +1.6-2.0% decode. Set to "0" (or drop the key) to get upstream's window
      # graph back byte for byte once we have a capture.
      # The GUARD is upstream's now (#1892, on by default, STRATA_NAN_GUARD=0 disables):
      # the poisoned window emits nothing, the caches are dropped and the prompt is read
      # again from token 0, so this only observes - it never changes an answer.
      env.STRATA_KERNEL_AUDIT = "1";
      # 0.1.44 turned on TWO more RDNA4 defaults that apply to us and we deliberately take
      # them (upstream's numbers, not our measurements - so these are the first suspects if an
      # answer changes or a prompt behaves differently after that deploy, and the A/B is one
      # line each way):
      #   * STRATA_HC_Q8 - on by default for gfx1200/gfx1201 (native_dense.cpp:46-70). The
      #     hyper-connection projections are read as Q8_0 instead of BF16: R9700 decode
      #     +2.5..4%, mean KL 0.0003-0.0010, so answers CAN differ in near-ties. For our pack
      #     (repacked with --compat-bf16, so its 195 hc_* tensors are BF16) the engine
      #     requantizes that BF16 copy to Q8_0 at load - a little more load time and arena.
      #     Revert: env.STRATA_HC_Q8 = "0";
      #   * STRATA_GFX12_CHUNK - a bare `--prefill auto` (what engineArgs passes) may now chunk
      #     prompts at 16384 instead of 8192 on gfx12. 0.1.44's #2090 guard keeps 8192 when the
      #     available RAM does not cover the extra slot loan + 6 GiB, which is the case worth
      #     watching here: --resident-budget-gib 55 on 94 GB. Revert: env.STRATA_GFX12_CHUNK =
      #     "0"; (or STRATA_GFX12_DEFAULTS = "0" for both at once).
      # Carried over from 0.1.43 and unchanged: STRATA_ROUTE_TAIL_SKIP=7 and the measured PCIe
      # share are still on for gfx12 (we hold ~43% of the experts in the GPU cache, so the skip
      # is active; KL ~0.003-0.006). `STRATA_ROUTE_TAIL_SKIP=0 --pcie-frac 0` is the A/B the
      # maintainer asks for while #879 is open - pin those before reporting a capture.
      # Hang watchdog (#29) work-around, 2026-10-08: ROCr maps paged host
      # allocations through a KFD userptr, and while the kernel reclaims those
      # host pages the GPU's queues get suspended; a restore that keeps
      # returning -EAGAIN leaves them suspended for tens of seconds -> "no
      # progress for 60 s" during long-prompt prefill (we hit it at 49K-186K
      # tokens, with --kv-resident 32768 streaming KV into host RAM). Setting
      # this to 0 makes ROCr use plain mmap/ioctl instead of userptr.
      # Upstream report #750 is two Radeon AI PRO R9700 on ROCm 7.2 - this box
      # (rocm-runtime 7.2.3, clr 7.2.3; the knob string is present in
      # libhsa-runtime64.so.1). Their measurement: same outputs, same median
      # (16.65 s vs 16.63 s), the 29.8 s / 42.2 s outliers gone, solo requests
      # a little slower (3.55 -> 3.69 s). One change at a time: if this does
      # not move it, the next candidate is GPU_PINNED_MIN_XFER_SIZE=1048576
      # (#920). Details: docs/strata-hang.md.
      env.HSA_USERPTR_FOR_PAGED_MEM = "0";
    }
  );

  strataRootLocation = {
    proxyPass = "http://127.0.0.1:8080";
    recommendedProxySettings = true;
    proxyWebsockets = true;
    extraConfig = ''
      # First token can take minutes (the engine loads ~70 GB / fills the
      # expert cache); SSE must stream un-buffered.
      proxy_read_timeout 3600s;
      proxy_send_timeout 3600s;
      proxy_buffering off;
    '';
  };
in
{
  systemd.services.strata = {
    description = "Strata (Qwen3.8-Flash-Next across GPU VRAM, RAM and CPU)";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    # Don't crash-loop before the hand-run model prep has produced a pack.
    unitConfig.ConditionPathExists = "${m.packDir}/index.txt";

    serviceConfig = {
      ExecStart = "${strata}/bin/strata-server --engine strata --config ${configFile} --host 127.0.0.1 --port 8080";
      # The engine log (config "log") is written here; StateDirectory creates it.
      StateDirectory = "strata";
      Restart = "on-failure";
      RestartSec = 10;
      # No core dumps. The engine's hang watchdog (#29) SIGABRTs itself, and
      # each dump was 32 GB of model weights + KV on "/" (81 G free) - and
      # useless: bin/strata is stripped with no build-id, so there is nothing
      # to symbolize, and all 41 threads sit in libc syscall stubs waiting on
      # the GPU. The journal line names the stall (layer + token) instead.
      # Full write-up: docs/strata-hang.md.
      LimitCORE = "0";
      # Loading the model is a multi-minute, tens-of-GB operation.
      TimeoutStartSec = "infinity";
      TimeoutStopSec = 120;
    };
  };

  services.nginx.virtualHosts = {
    # ---- IP vhost: Strata at the root (the location llama-swap used). ----

    "192.168.49.50".locations = {
      "/" = strataRootLocation;
    };

    # ---- Public subdomain ----

    "strata.ai.chrisdell.info" = {
      useACMEHost = "ai.chrisdell.info";
      forceSSL = true;
      locations."/" = strataRootLocation;
    };
  };
}
