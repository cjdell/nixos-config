{ pkgs, ... }:

# Alexandria audiobook generator (github.com/cjdell/alexandria-audiobook — fork
# of Finrandojin/alexandria-audiobook carrying ROCm fixes). Cloned to
# ~/Projects/alexandria-audiobook; WebUI on port 4200.
#
# nginx: owns the public alexandria.ai.chrisdell.info subdomain (root -> the
# container's WebUI on 127.0.0.1:4200). No IP-vhost /alexandria prefix:
# FastAPI serves index.html at "/" with no prefix handling, so the subdomain
# (app at the root, no rewriting — the recallium.ai pattern) is the only
# proxied path; LAN users can still hit the WebUI directly on :4200.
#
# It turns books into voiced audiobooks: an OpenAI-compatible LLM (point it at
# llama-swap on this box, see below) annotates the script and the built-in
# Qwen3-TTS engine voices it.
#
# The upstream Docker image is CUDA-tagged, but this box has no NVIDIA GPU, so
# the container runs the ROCm build of PyTorch (Dockerfile.rocm: torch
# 2.8.0+rocm6.4 + ROCm torchaudio, no torchvision — see the repo's AGENTS.md)
# and gets the GPU via /dev/kfd + its render node, so Qwen3-TTS sees it as a
# HIP "cuda" device.
#
# GPU: the R9700 (Radeon AI PRO R9700, Navi 48 / gfx1201, 32 GB) — render node
# /dev/dri/renderD128 (by-path pci-0000:03:00.0-render; render minors are NOT
# card order on this box: Vega iGPU is card0 but renderD130, RX 580 renderD129).
# ⚠️ The R9700 also hosts llama-swap's resident coding model (~26 GB VRAM) and
# a 64 GiB RAM prompt cache (`-cram 65536` — the OOM history): unload the LLM
# before a TTS run or the model load will fail / push the box toward OOM:
#   curl -X POST http://127.0.0.1:8081/api/models/unload
#
# HSA_OVERRIDE_GFX_VERSION is deliberately UNSET: gfx1201 is the R9700's native
# RDNA4 target. (The aibox template sets 10.3.0 only because its Radeon 660M
# iGPU, gfx1035, is not a torch wheel target.) If the ROCm 6.4 wheel turns out
# to lack gfx1201 code objects, the first HIP launch fails with "invalid device
# function" — then the torch wheel must be built for gfx1201; an override to
# another RDNA generation's ISA will not execute on RDNA4.
#
# Images are built manually from the clone (docker.io CUDA base, ~9 GB; :rocm
# adds the self-contained ROCm 6.4 torch wheel, ~22 GB total):
#   cd ~/Projects/alexandria-audiobook
#   sudo podman build -t localhost/alexandria:latest .
#   sudo podman build -f Dockerfile.rocm -t localhost/alexandria:rocm .
# (rebuild :rocm whenever :latest changes; restart podman-alexandria to pick
# up the new image)
#
# LLM annotation endpoint: set in the WebUI settings (llm.base_url in
# config.json). llama-swap's OpenAI-compatible routers are reachable from the
# container at host.containers.internal:8081 (llama-swap binds 0.0.0.0:8081 and
# this host has no firewall) — same /upstream/<gpu>/v1 layout nginx exposes on
# llm.ai.chrisdell.info:
#   http://host.containers.internal:8081/upstream/vega/v1   (default: small
#     models on the Vega 8 iGPU, the same router as Recallium)
#   http://host.containers.internal:8081/upstream/r9700/v1  (big models — but
#     that GPU is busy with TTS here; unload first, see above)
#
# journalctl -u podman-alexandria -f
# sudo podman exec -ti alexandria sh

let
  dataDir = "/home/cjdell/Projects/alexandria-audiobook/data";
  dataSubdirs = [
    "config"
    "uploads"
    "designed_voices"
    "clone_voices"
    "lora_models"
    "lora_datasets"
    "dataset_builder"
    "scripts"
    "output"
    "hf-cache"
  ];
in
{
  virtualisation.oci-containers.containers.alexandria = {
    hostname = "alexandria";
    image = "localhost/alexandria:rocm";
    autoStart = true;
    ports = [
      "4200:4200"
    ];
    volumes = [
      # WebUI settings (OpenAI endpoint, prompts, TTS mode, ...)
      "${dataDir}/config:/alexandria/config"
      # User uploads (source books)
      "${dataDir}/uploads:/alexandria/app/uploads"
      # User-generated assets / state
      "${dataDir}/designed_voices:/alexandria/designed_voices"
      "${dataDir}/clone_voices:/alexandria/clone_voices"
      "${dataDir}/lora_models:/alexandria/lora_models"
      "${dataDir}/lora_datasets:/alexandria/lora_datasets"
      "${dataDir}/dataset_builder:/alexandria/dataset_builder"
      "${dataDir}/scripts:/alexandria/scripts"
      # Audiobook output
      "${dataDir}/output:/alexandria/voicelines"
      # HuggingFace model cache (~3.5 GB per model, downloaded on first use)
      "${dataDir}/hf-cache:/root/.cache/huggingface"
      "/etc/localtime:/etc/localtime:ro"
    ];
    environment = {
      # Mirrors docker-compose.yml. The worker subprocesses resolve it via this
      # env var too (fork commit adb3a66) — otherwise they silently fall back to
      # the hardcoded localhost:11434 Ollama defaults and ignore the WebUI LLM
      # settings.
      ALEXANDRIA_CONFIG_PATH = "/alexandria/config/config.json";
    };
    # AMD GPU passthrough for the ROCm PyTorch build (KFD + the R9700's render
    # node). HSA_OVERRIDE_GFX_VERSION deliberately unset — see the header.
    extraOptions = [
      # Rootful podman: resolve host.containers.internal to the host so the
      # WebUI's llm.base_url can reach llama-swap on 8081.
      "--add-host=host.containers.internal:host-gateway"
      "--add-host=host.docker.internal:host-gateway"
      "--device=/dev/kfd"
      "--device=/dev/dri/renderD128"
    ];
  };

  # Podman refuses bind mounts whose host dir is missing ("statfs: no such
  # file or directory"), so create the data dirs before every start. The app
  # state (WebUI settings, uploads, voices, LoRAs, output) lives here so it
  # survives container recreations (the generated unit `podman rm -f`s + re-
  # runs on every start).
  systemd.services.podman-alexandria.serviceConfig.ExecStartPre = [
    (pkgs.writeShellScript "alexandria-data-dirs" ''
      mkdir -p ${dataDir} ${builtins.concatStringsSep " " (map (d: "${dataDir}/${d}") dataSubdirs)}
      chown cjdell:users ${dataDir}
      chmod 0775 ${dataDir} ${builtins.concatStringsSep " " (map (d: "${dataDir}/${d}") dataSubdirs)}
    '')
  ];

  services.nginx.virtualHosts = {
    # ---- Public subdomain ----

    "alexandria.ai.chrisdell.info" = {
      useACMEHost = "ai.chrisdell.info";
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:4200";
        recommendedProxySettings = true;
        proxyWebsockets = true;
        extraConfig = ''
          # Script generation + TTS setup calls can take minutes.
          proxy_read_timeout 600s;
          proxy_send_timeout 600s;
        '';
      };
    };
  };
}
