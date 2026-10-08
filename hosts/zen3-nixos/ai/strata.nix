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

let
  strata = pkgs.callPackage ./strata-package.nix { };

  # Model layout. The GGUFs stay where they were downloaded (~/Models); only
  # the hand-prepared pack and MTP runtime live under modelDir.
  ggufDir = "/home/cjdell/Models/Qwen3.8-Flash-Next-GSQ-RCO-GGUF";
  modelDir = "/home/cjdell/Strata";
  packDir = "${modelDir}/pack/iq3s";
  nativeGguf = "${ggufDir}/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-00001-of-00002.gguf";
  pleGguf = "${ggufDir}/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-00002-of-00002.gguf";
  mtpDir = "${modelDir}/mtp/rt";

  # The profile ships in the repo; the copy in the store is fine (the engine
  # only reads it).
  expertProfile = "${strata}/share/strata/data/expert-profile.bin";

  # Measured ceiling for this box (93 GB RAM, 32 GB R9700) - see docs/strata.md:
  # 262144 is the model's native window and the quality/prefill knee. With
  # --kv-resident 32768 the int8 KV (~13.7 KB/token) lives in RAM, so the VRAM
  # expert cache stays ~25 GiB whatever the context; RAM used grew ~49 GB at
  # 256K, ~52 GB at 512K, ~59 GB at 1M, ~72 GB at 2M. 262144 needs no rope
  # scaling; past it the engine adds yarn (factor = ctx/262144) and fresh
  # prefill falls off (measured: 1393 t/s at 121K depth, 1184 at 255K, 728 at
  # 486K, 376 at 931K), so raise only when the length is really needed.
  context = 262144;

  # Mirrors setup.py's args for the 2-shard native IQ3_XXS pack (setup.py:4224),
  # with --kv int8 and KV streaming (--kv-resident) for the long context.
  # --ple-gguf is the shard holding the per_layer_token_embd table (shard 2).
  engineArgs = [
    "--pack"
    packDir
    "--native"
    nativeGguf
    "--ple-gguf"
    pleGguf
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
    "--kv"
    "int8"
    "--kv-resident"
    "32768"
  ];

  # The run config serve/server.py reads: the engine binary (the Nix build),
  # its args, and the tokenizer. Kept read-only in the store for now; edit
  # this file and rebuild to change engine args (the web Settings view would
  # need a writable copy in /var/lib/strata instead).
  configFile = pkgs.writeText "strata-iq3s.json" (
    builtins.toJSON {
      exe = "${strata}/bin/strata";
      args = engineArgs;
      cwd = "/var/lib/strata";
      tokenizer = "${packDir}/tokenizer";
      model_name = "qwen3.8-flash-next-iq3s";
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
      env.HIP_VISIBLE_DEVICES = "0";
      # Local #879 instrumentation (see strata-package.nix): when the finiteness
      # guard trips, dump the first non-finite (layer, row, col, raw bits) per
      # grouped-expert stage. Tracks down whether our fire is the same
      # 0x7FFFFFFF routed-expert data-path garbage the CUDA reporter saw.
      # Costs an extra scan per stage per layer -> mostly prefill; set to "0"
      # (or drop the key) once we have a capture. The guard itself stays on
      # regardless (STRATA_NAN_GUARD defaults to on).
      env.STRATA_KERNEL_AUDIT = "1";
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
    unitConfig.ConditionPathExists = "${packDir}/index.txt";

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
