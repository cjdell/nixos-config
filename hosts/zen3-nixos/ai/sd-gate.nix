{
  config,
  lib,
  pkgs,
  ...
}:

# stable-diffusion.cpp on demand: sd-gate fronts port 8084 (nginx /sd-api +
# sd.ai.chrisdell.info target) and only keeps sd-server (and the SDXL model
# in VRAM) alive while it is used. 120 s idle -> killed -> VRAM freed for
# llama-swap's resident model.
#
# nginx: owns the /sd* locations on the IP vhost plus the public
# sd.ai.chrisdell.info subdomain (static UI at the root, API, status page).

let
  # nixpkgs default is a CPU-only build (SD_VULKAN=OFF); enable the Vulkan
  # backend for the R9700. Same derivation as the systemPackages entry in
  # ./default.nix (identical args -> identical store path).
  stable-diffusion-cpp-vulkan = pkgs.stable-diffusion-cpp.override { vulkanSupport = true; };

  # On-demand SD: always listens on 8084 (nginx /sd-api target), spawns
  # sd-server (8085) on the first request, kills it after --idle seconds of
  # no traffic so the R9700 VRAM is freed. See sd-gate/.
  sd-gate = pkgs.rustPlatform.buildRustPackage {
    pname = "sd-gate";
    version = "0.1.0";
    src = ../../../sd-gate;
    cargoLock.lockFile = ../../../sd-gate/Cargo.lock;
    doCheck = false;
  };

  # Static web UI for sd-server, copied into the store so nginx (non-root
  # user) can serve it — it cannot read /home/cjdell (mode 700).
  sd-webui = pkgs.runCommandLocal "sd-webui" { src = ../../../sd-webui; } "cp -r $src $out";

  # The API is the same behind the IP vhost's /sd-api/ prefix (the UI's
  # hardcoded path, prefix stripped) and sd.ai.chrisdell.info's /sd-api/,
  # /sdapi/ and /v1/ (prefix-less for scripts, e.g. OpenAI-style
  # https://sd.ai.chrisdell.info/v1/images/generations — note that style
  # ignores steps/cfg/seed on this build).
  sdApiLocation = {
    proxyPass = "http://127.0.0.1:8084";
    recommendedProxySettings = true;
    extraConfig = ''
      rewrite ^/sd-api/?(.*)$ /$1 break;
      # SD generations take tens of seconds; don't let nginx time out.
      proxy_read_timeout 600s;
      proxy_send_timeout 600s;
    '';
  };

  sdApiNoPrefixLocation = {
    proxyPass = "http://127.0.0.1:8084";
    recommendedProxySettings = true;
    extraConfig = ''
      proxy_read_timeout 600s;
      proxy_send_timeout 600s;
    '';
  };

  # sd-gate status page: why is the model loaded? (state, idle-unload
  # countdown, VRAM, active clients). JSON at /sd-status/status.
  sdStatusLocation = {
    proxyPass = "http://127.0.0.1:8086";
    recommendedProxySettings = true;
    extraConfig = ''
      rewrite ^/sd-status/?(.*)$ /$1 break;
    '';
  };
in
{
  systemd.services.sd-gate = {
    description = "On-demand stable-diffusion.cpp server (loads on first request, unloads when idle)";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    # Pin the spawned sd-server to the R9700 with the same device-select layer
    # pin as llama-swap: without MESA_VK_DEVICE_SELECT the layer's boot-VGA
    # default exposes the iGPU first and `--backend vulkan0` would put SDXL on
    # the Vega. With the pin, vulkan0 = the R9700 (the only visible device).
    environment = {
      XDG_DATA_DIRS = "/run/opengl-driver/share";
      MESA_VK_DEVICE_SELECT = "1002:7551!";
    };

    serviceConfig = {
      # --vae-tiling is required: RADV caps maxMemoryAllocationSize at ~4 GiB
      # on the R9700, and the SDXL VAE decode graph (~8.5 GB) OOMs without it.
      # --max-vram -1 sizes compute graphs to whatever VRAM is free so SD stays
      # polite next to llama-swap's resident model. See AGENTS.md.
      # --min-vram-gib 10: below 10 GiB free (i.e. the llama-swap LLM is
      # resident) the gate posts to llama-swap's /api/models/unload and waits
      # for the VRAM before loading SDXL. Status page: /sd-status/ via nginx.
      ExecStart = "${sd-gate}/bin/sd-gate --listen 127.0.0.1:8084 --status-listen 127.0.0.1:8086 --upstream 127.0.0.1:8085 --idle 120 --ready-timeout 180 --min-vram-gib 10 --vram-tool /run/current-system/sw/bin/amd-smi -- ${stable-diffusion-cpp-vulkan}/bin/sd-server --listen-ip 127.0.0.1 --listen-port 8085 --backend diffusion=vulkan0,clip=vulkan0,vae=vulkan0 --vae-tiling --max-vram -1 -m /home/cjdell/sd-models/sd_xl_base_1.0.safetensors --vae /home/cjdell/sd-models/sdxl_vae.fp16.safetensors --clip_l /home/cjdell/sd-models/clip_l.fp16.safetensors --clip_g /home/cjdell/sd-models/clip_g.fp16.safetensors";
      # Safety net: if the gate is SIGKILLed (stop timeout), kill the
      # sd-server it spawned so its VRAM is not left loaded.
      ExecStop = "${pkgs.bash}/bin/bash -c 'if [ -f /run/sd-gate.pid ]; then kill \"$(cat /run/sd-gate.pid)\" 2>/dev/null || true; rm -f /run/sd-gate.pid; fi'";
      Restart = "always";
      RestartSec = 5;
      TimeoutStopSec = 20;
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

      "= /sd-status" = {
        return = "301 /sd-status/";
      };

      "/sd-status/" = sdStatusLocation;
    };

    # ---- Public subdomain ----

    # stable-diffusion.cpp: static web UI at the root; the UI's hardcoded
    # /sd-api/... calls plus prefix-less /sdapi/ and /v1/ for scripts; and
    # the sd-gate status page.
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
        "= /sd-status" = {
          return = "301 /sd-status/";
        };
        "/sd-status/" = sdStatusLocation;
      };
    };
  };
}
