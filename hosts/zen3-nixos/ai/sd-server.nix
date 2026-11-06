{
  config,
  lib,
  pkgs,
  ...
}:

# Stable Diffusion on the R9700 via stable-diffusion.cpp (Vulkan), now serving
# FLUX.1-schnell (Q8_0 GGUF). This replaces the sd-gate pattern (retired
# 2026-11-06): `gpu-mode` is how this box schedules the card, so the
# spawn-on-first-connection and 120 s idle-kill of the gate are gone - an
# 18 GB model must not ping-pong through VRAM. `gpu-mode sd` starts this unit
# and waits for /v1/models; `gpu-mode llm|game` stops it. Deliberately NO
# wantedBy, exactly like sd-gate had none.
#
# Weights live in /home/cjdell/sd-models (see ../../../scripts/fetch-flux-schnell.sh
# for sources + checksums): the 12.7 GB schnell Q8_0 DiT, t5xxl fp8_scaled +
# clip_l text encoders, and the flux autoencoder (ae.safetensors).
# ConditionPathExists refuses to start the unit on an unprepared set.
#
# VRAM: ~12 GB DiT + ~5 GB t5 + compute graphs fits the 32 GB card easily
# while Strata is off lease. --guidance 1.0 because schnell is
# guidance-distilled (the 3.5 default is FLUX-dev's); --cfg-scale 1.0 server
# default (schnell runs without the CFG branch - the web UI sends its own).
# --vae-tiling stays: RADV caps maxMemoryAllocationSize at ~4 GiB on the
# R9700, and the flux AE decode wants bigger buffers than that.
#
# This service still owns the nginx /sd* locations on the IP vhost plus the
# public sd.ai.chrisdell.info subdomain - same URLs as the sd-gate era, minus
# the gate's /sd-status page (which no longer exists).

let
  # nixpkgs default is a CPU-only build (SD_VULKAN=OFF); enable the Vulkan
  # backend for the R9700. Same derivation as the systemPackages entry in
  # ./default.nix (identical args -> identical store path).
  stable-diffusion-cpp-vulkan = pkgs.stable-diffusion-cpp.override { vulkanSupport = true; };

  models = "/home/cjdell/sd-models";

  # Static web UI for sd-server, copied into the store so nginx (non-root
  # user) can serve it — it cannot read /home/cjdell (mode 700).
  sd-webui = pkgs.runCommandLocal "sd-webui" { src = ../../../sd-webui; } "cp -r $src $out";

  # The API is the same behind the IP vhost's /sd-api/ prefix (the UI's
  # hardcoded path, prefix stripped) and sd.ai.chrisdell.info's /sd-api/,
  # /sdapi/ and /v1/ (prefix-less for scripts, e.g. OpenAI-style
  # https://sd.ai.chrisdell.info/v1/images/generations — note that style
  # ignores steps/cfg/seed on this build).
  sdApiLocation = {
    proxyPass = "http://127.0.0.1:8085";
    recommendedProxySettings = true;
    extraConfig = ''
      rewrite ^/sd-api/?(.*)$ /$1 break;
      # Flux generations are fast but model load is not; don't let nginx time out.
      proxy_read_timeout 600s;
      proxy_send_timeout 600s;
    '';
  };

  sdApiNoPrefixLocation = {
    proxyPass = "http://127.0.0.1:8085";
    recommendedProxySettings = true;
    extraConfig = ''
      proxy_read_timeout 600s;
      proxy_send_timeout 600s;
    '';
  };
in
{
  systemd.services.sd-server = {
    description = "stable-diffusion.cpp Flux-schnell server (started by gpu-mode sd)";
    after = [ "network.target" ];
    # Deliberately NO wantedBy: the card is a lease, and `gpu-mode sd` owns
    # starting/stopping this unit (boot default is the llm lease - strata).

    # Pin to the R9700 with the mesa device-select layer (see AGENTS.md
    # "GPU pinning"): with the trailing `!` vulkan0 is always the R9700 and
    # the console GPU is invisible, so --backend ...=vulkan0 cannot drift.
    environment = {
      XDG_DATA_DIRS = "/run/opengl-driver/share";
      MESA_VK_DEVICE_SELECT = "1002:7551!";
    };

    serviceConfig = {
      ExecStart = "${stable-diffusion-cpp-vulkan}/bin/sd-server --listen-ip 127.0.0.1 --listen-port 8085 --backend diffusion=vulkan0,clip=vulkan0,vae=vulkan0 --vae-tiling --max-vram -1 --guidance 1.0 --cfg-scale 1.0 --diffusion-model ${models}/flux1-schnell-Q8_0.gguf --clip_l ${models}/clip_l.safetensors --t5xxl ${models}/t5xxl_fp8_e4m3fn_scaled.safetensors --vae ${models}/ae.safetensors";
      # The four weights must be fetched first (scripts/fetch-flux-schnell.sh).
      ConditionPathExists = [
        "${models}/flux1-schnell-Q8_0.gguf"
        "${models}/clip_l.safetensors"
        "${models}/t5xxl_fp8_e4m3fn_scaled.safetensors"
        "${models}/ae.safetensors"
      ];
      # The model load reads ~18 GB; on a cold page cache that is minutes,
      # not seconds - don't let the default start timeout kill it.
      TimeoutStartSec = "15min";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  services.nginx.virtualHosts = {
    # ---- IP vhost (192.168.49.50): the path-based /sd* layout. ----

    "192.168.49.50".locations = {
      "= /sd" = {
        return = "301 /sd/";
      };

      "/sd/" = {
        alias = "${sd-webui}/";
        index = "index.html";
      };

      "/sd-api/" = sdApiLocation;
    };

    # ---- Public subdomain ----

    # static web UI at the root; the UI's hardcoded /sd-api/... calls plus
    # prefix-less /sdapi/ and /v1/ for scripts.
    "sd.ai.chrisdell.info" = {
      useACMEHost = "ai.chrisdell.info";
      forceSSL = true;
      locations = {
        "/" = {
          alias = "${sd-webui}/";
          index = "index.html";
        };
        "/sd-api/" = sdApiLocation;
        "/sdapi/" = sdApiNoPrefixLocation;
        "/v1/" = sdApiNoPrefixLocation;
      };
    };
  };
}
