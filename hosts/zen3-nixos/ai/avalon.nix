{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

# Avalon on the R9700 (HIP/gfx1201) - the Qwen3.8-Flash-Next server that
# replaces Strata (github.com/freriadoc/Avalon, llama.cpp fork; the engine
# itself is packaged in ./avalon-package.nix).
#
# SAME URL ON PURPOSE: this unit takes over 127.0.0.1:8080 and the exact
# nginx locations strata.nix used ("/" on the IP vhost +
# strata.ai.chrisdell.info, with llm./llama.ai arriving through ../tls.nix's
# wildcard fallback and Recallium's /recallium-llm/ proxy in ./recallium.nix
# untouched). Every client - opencode, the Pi lane, Recallium,
# https://strata.ai.chrisdell.info - keeps its URL and its model name:
# llama.cpp's server answers whichever model is loaded regardless of the
# `model` field it is sent (no model-name check anywhere in tools/server).
# The unit is named `avalon`; only the HTTP surface has to be stable.
#
# Model data is NOT in the store. Prepare it once with
#
#   scripts/fetch-avalon-model.sh    # ~89 GiB, size + sha256 pinned, resumable
#
# into /home/cjdell/Models/Qwen3.8-Flash-Next-Avalon-GGUF: the 33 IQ3_KS-hybrid
# shards (the GGUF llama-server opens is shard 1; it finds the rest by name),
# the MTP draft head under MTP/, and moe-cache-ranking.bin (the expert
# pre-ranking the cache is prefilled from). ConditionPathExists refuses to
# start an unprepared model, so a rebuild without the download is inert - the
# unit stays inactive rather than crash-looping.
#
# The run line is Avalon's documented `avalon-server` command verbatim (its
# README "Run" + install.sh's launcher): 262144 ctx (the model's native
# window; Strata's 393216-via-YaRN experiment is deliberately not repeated
# until Avalon answers on >256K), chunk/ubatch 9536, FA on, KV q8_0/q4_0,
# --parallel 1 (more slots would each hold their part of the KV - same
# one-slot finding as strata-batching.md), MTP with 2 draft tokens and the
# draft KV at q8_0. --fit (on by default) places the dense weights + KV on
# the GPU and keeps the experts in RAM, the expert cache takes the rest of
# the VRAM, and it is prefilled from moe-cache-ranking.bin - nothing to size
# by hand. Additions over the README line, each small and reversible:
#
#   --alias                names /v1/models "qwen3.8-flash-next" (the
#                          default is the shard's file name)
#   --cache-reuse 256      reuse a shifted KV prefix instead of re-reading
#                          from token 0 (the llama-swap-era setting)
#   -cram 16384            16 GiB cap on the RAM prompt cache (llama.cpp
#                          counts it in MIB, not tokens - default 8192).
#                          Explicit and half of what llama-swap ran daily:
#                          the -cram 65536 (64 GiB) of that era OOM'd this
#                          box (AGENTS.md, the RAM bullet), and zram is the
#                          backstop, not the plan.
#   --log-prompts-dir      feeds llama-logs/, the same %012lld-ms .txt capture
#                          llama-log-viewer (crates/llama-log-viewer) reads -
#                          revives the viewer, which has been dark since
#                          llama-swap stopped writing it (Oct 4).
#   --slots                exposes GET /slots, which ./gpu-mode.sh reads for
#                          its "requests in flight" warning before a switch
#                          (llama.cpp keeps the endpoint off by default).
#
# GPU leasing differs from ./strata.nix in ONE way: llama.cpp's server has no
# unload endpoint (Strata's POST /v1/unload is gone), so nothing can evict the
# model from inside the running process. The lease is therefore purely unit
# state - ./gpu-mode.nix stops avalon.service for sd/game - which is how the
# lease already worked; only the cooperative fallback (sd-gate asking the LLM
# to unload on an ad-hoc overlap) is replaced by sd-gate proceeding at
# GTT-spill speed. Strata's auto-reload-on-next-request is gone too: `gpu-mode
# llm` starts the unit and waits on /health, which flips to 200 exactly when
# the model is resident.

let
  avalonServer = pkgs.callPackage ./avalon-package.nix {
    avalonSrc = inputs.avalon;
  };

  modelDir = "/home/cjdell/Models/Qwen3.8-Flash-Next-Avalon-GGUF";
  gguf = "${modelDir}/Qwen3.8-Flash-Next-Avalon-IQ3KS-00001-of-00033.gguf";
  mtpHead = "${modelDir}/MTP/mtp-Qwen3.8-Flash-Next-shared-IQ3K-IQ4NL-FR65k.gguf";
  expertRanking = "${modelDir}/moe-cache-ranking.bin";

  # The llama-logs capture llama-log-viewer indexes (AGENTS.md "llama-log-viewer").
  logsDir = "/home/cjdell/nixos-config/llama-logs";

  # Image input (ENABLED 2026-11-04). The ISTA mtmd encoder this box already
  # held worked under Strata (its strata-vision IS llama.cpp mtmd), and
  # Avalon's fork reads the same file: its tools/mtmd carries models/qwen3vl.cpp
  # and accepts the file's `qwen3vl_merger` projector type. Verified before
  # enabling (zero-risk, CPU-only, did not touch the service): llama-mtmd-cli
  # with this exact binary + mmproj loaded the encoder and answered "red" on a
  # 256x256 red PNG. --no-mmproj-offload keeps the ~1 GiB BF16 encoder in RAM:
  # the expert cache leaves only ~100 MiB of VRAM free, so GPU-offloading it
  # cannot work. Encoding is ~5 s/image on CPU - same ballpark as the Strata
  # era, whose encoder also ran as a separate (CPU) process.
  # NOTE: the flag is unconditional, so deleting this file WITHOUT removing the
  # flag below takes the whole service down at load (llama.cpp exits on a
  # missing --mmproj, and Restart=on-failure loops).
  mmproj = "/home/cjdell/Models/mmproj-Qwen3.8-Flash-Next-BF16.gguf";

  avalonRootLocation = {
    proxyPass = "http://127.0.0.1:8080";
    recommendedProxySettings = true;
    proxyWebsockets = true;
    extraConfig = ''
      # First token can take minutes (the model is ~89 GiB mmap'd and the
      # expert cache fills from disk on load); SSE must stream un-buffered.
      proxy_read_timeout 3600s;
      proxy_send_timeout 3600s;
      proxy_buffering off;
      # Body cap matches strata.nix's: base64 pictures in a chat request must
      # not 413 at the proxy (llama.cpp's own cap is 1024 MiB by default, so
      # this stays the binding limit either way).
      client_max_body_size 32m;
    '';
  };
in
{
  systemd.services.avalon = {
    description = "Avalon llama-server (Qwen3.8-Flash-Next, HIP/gfx1201, MTP)";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    # Don't crash-loop before scripts/fetch-avalon-model.sh has produced the
    # model: llama-server exits on a missing shard, and Restart would loop.
    unitConfig.ConditionPathExists = [
      gguf
      mtpHead
      expertRanking
    ];

    serviceConfig = {
      # Avalon's documented command (install.sh's avalon-server launcher),
      # plus the extra flags documented at the top. -m takes shard 1 of the
      # split GGUF; llama.cpp opens 00002-of-00033 .. by sibling name.
      ExecStart = ''
        ${avalonServer}/bin/llama-server \
          -m ${gguf} \
          -c 262144 -b 9536 -ub 9536 -fa on -ctk q8_0 -ctv q4_0 --jinja --parallel 1 \
          -md ${mtpHead} --spec-type draft-mtp --spec-draft-n-max 2 -ubd 256 -ctkd q8_0 -ctvd q8_0 \
          --alias qwen3.8-flash-next \
          --mmproj ${mmproj} --no-mmproj-offload \
          --cache-reuse 256 -cram 16384 --slots \
          --log-prompts-dir ${logsDir} \
          --host 127.0.0.1 --port 8080
      '';
      # The ranking preload looks next to the model; install.sh also runs the
      # server from the model dir. Match it.
      WorkingDirectory = modelDir;
      # One compute GPU exists (the R9700); pin it exactly like strata.nix did
      # - the RX 580 console is gfx803 and has no kernels here anyway.
      Environment = [ "HIP_VISIBLE_DEVICES=0" ];
      Restart = "on-failure";
      RestartSec = 10;
      # Loading = mmap 89 GiB + expert-cache fill from moe-cache-ranking.bin.
      TimeoutStartSec = "infinity";
      TimeoutStopSec = 120;
      # No core dumps: "/" has 35 G free and a dump of this process would be
      # tens of GB (the strata.nix LimitCORE reasoning, unchanged).
      LimitCORE = "0";
    };
  };

  services.nginx.virtualHosts = {
    # ---- IP vhost: Avalon at the root (the location strata.nix served). ----

    "192.168.49.50".locations = {
      "/" = avalonRootLocation;
    };

    # ---- Public subdomain: the name clients already point at. ----
    # strata.ai.chrisdell.info still resolves to this box and answers the same
    # OpenAI-compatible API; renaming it (an avalon. cert name = a new ACME
    # SAN set) would buy nothing. ../tls.nix's wildcard fallback still serves
    # the same locations for llm.ai / llama.ai and the apex.

    "strata.ai.chrisdell.info" = {
      useACMEHost = "ai.chrisdell.info";
      forceSSL = true;
      locations."/" = avalonRootLocation;
    };
  };
}
