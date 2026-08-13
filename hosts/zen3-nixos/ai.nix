{
  config,
  lib,
  pkgs,
  specialArgs,
  ...
}:

let
  llama-log-viewer = pkgs.rustPlatform.buildRustPackage {
    pname = "llama-log-viewer";
    version = "0.1.0";
    src = ../../llama-log-viewer;
    cargoLock.lockFile = ../../llama-log-viewer/Cargo.lock;
    doCheck = false;
  };
in
{
  environment.systemPackages = with pkgs; [
    rocmPackages.rocminfo
    rocmPackages.amdsmi
  ];

  # I think stable-diffusion-webui needs this
  systemd.tmpfiles.rules = [
    "L+    /opt/rocm   -    -    -     -    ${pkgs.rocmPackages.clr}"
  ];

  # Stop crashes for large context sizes
  boot.kernelParams = [ "amdgpu.lockup_timeout=10000" ];

  systemd.services.llama-swap = {
    description = "Llama Swap";
    after = [ "wait-for-network.service" ];
    wants = [ "wait-for-network.service" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      HSA_OVERRIDE_GFX_VERSION = "9.0.0";
      # GGML_VK_LOG_SUBMISSIONS = "1";
      # GGML_VK_SERIALIZE_SUBMISSIONS = "1";
    };

    serviceConfig =
      let
        llama-cpp-cpu = specialArgs.inputs.llama-cpp.packages.${pkgs.stdenv.hostPlatform.system}.default;
        llama-cpp-vulkan =
          specialArgs.inputs.llama-cpp-uma.packages.${pkgs.stdenv.hostPlatform.system}.vulkan;
        llama-cpp-rocm = specialArgs.inputs.llama-cpp-uma.packages.${pkgs.stdenv.hostPlatform.system}.rocm;

        llamaCmdCpu = "${llama-cpp-cpu}/bin/llama-server --host 127.0.0.1 --port \${PORT} -t 16 --log-prompts-dir /home/cjdell/nixos-config/llama-logs --verbose -lv 5";
        llamaCmdVulkan = "${llama-cpp-vulkan}/bin/llama-server --host 127.0.0.1 --port \${PORT} -t 12 -ngl all --log-prompts-dir /home/cjdell/nixos-config/llama-logs --verbose -lv 5";
        llamaCmdRocm = "${llama-cpp-rocm}/bin/llama-server --host 127.0.0.1 --port \${PORT} -t 12 -ngl all --log-prompts-dir /home/cjdell/nixos-config/llama-logs --verbose -lv 5";

        modelsPath = "/home/cjdell/Models";

        # Native Nix structure representing the YAML config
        llamaConfig = {
          models = {
            # "Qwen3.6-27B-Fable-Fus-711-UnHeretic-NM-DAU-NEO-MAX-NEO-Q4_K_M" = {
            #   cmd = "${llamaCmdVulkan} -m ${modelsPath}/Qwen3.6-27B-Fable-Fus-711-UnHeretic-NM-DAU-NEO-MAX-NEO-Q4_K_M.gguf --ctx-size 262144 --metrics --reasoning-preserve";
            # };

            # "Qwen3.6-27B-Fable-Fus-711-UnHeretic-NM-DAU-NEO-MAX-NEO-MTP-Q4_K_M" = {
            #   cmd = "${llamaCmdVulkan} -m ${modelsPath}/Qwen3.6-27B-Fable-Fus-711-UnHeretic-NM-DAU-NEO-MAX-NEO-MTP-Q4_K_M.gguf --ctx-size 262144 --metrics --reasoning-preserve";
            # };

            # "Qwen3-Coder-REAP-25B-A3B-Rust-Q4_K_M" = {
            #   cmd = "${llamaCmdVulkan} -m ${modelsPath}/Qwen3-Coder-REAP-25B-A3B-Rust-Q4_K_M.gguf --ctx-size 262144 --metrics";
            # };

            # "Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-Q4_K_M" = {
            #   cmd = "${llamaCmdVulkan} -m ${modelsPath}/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf --ctx-size 262144 --metrics --reasoning off";
            # };

            # "Laguna-S-2.1-UD-IQ4_NL" = {
            #   cmd = "${llamaCmdRocm} -m ${modelsPath}/Laguna-S-2.1-UD-IQ4_NL-00001-of-00003.gguf --ctx-size 262144 --metrics --reasoning-preserve";
            # };

            # "CPU_Laguna-S-2.1-UD-IQ4_NL" = {
            #   cmd = "${llamaCmdCpu} -m ${modelsPath}/Laguna-S-2.1-UD-IQ4_NL-00001-of-00003.gguf --ctx-size 262144 --metrics --reasoning-preserve";
            # };

            # "cpu" = {
            #   cmd = "${llamaCmdCpu} --models-dir /home/cjdell/Models --ctx-size 262144 --metrics --reasoning-preserve";
            # };

            "vulkan" = {
              cmd = "${llamaCmdVulkan} --models-dir /home/cjdell/Models --ctx-size 262144 --metrics --reasoning-preserve";
            };

            # "rocm" = {
            #   cmd = "${llamaCmdRocm} --models-dir /home/cjdell/Models --ctx-size 262144 --metrics --reasoning-preserve";
            # };
          };
        };

        # Convert native Nix structure to YAML
        configYaml = lib.generators.toYAML { } llamaConfig;
      in
      {
        ExecStart = "${lib.getExe pkgs.llama-swap} -listen 0.0.0.0:8081 -config ${pkgs.writeText "llama-swap-config" configYaml}";
        WorkingDirectory = modelsPath;
        Restart = "always";
      };
  };

  systemd.services.llama-log-viewer = {
    description = "Llama Log Viewer";
    after = [ "wait-for-network.service" ];
    wants = [ "wait-for-network.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      ExecStart = "${llama-log-viewer}/bin/llama-log-viewer --logs /home/cjdell/nixos-config/llama-logs --host 127.0.0.1 --port 8083";
      Restart = "always";
      RestartSec = 5;
    };
  };

  virtualisation.oci-containers.containers.diamcp = {
    hostname = "diamcp";
    image = "localhost/diamcp";
    autoStart = true;
    ports = [ "8082:8000" ];
    volumes = [
      "/home/cjdell:/workspace"
    ];
    extraOptions = [
      "--user=${toString config.users.users.cjdell.uid}:100"
    ];
  };

  services.nginx.virtualHosts = {
    "192.168.49.50" = {
      locations."/" = {
        proxyPass = "http://127.0.0.1:8081";
        recommendedProxySettings = true;
        proxyWebsockets = true;
      };

      locations."/mcp" = {
        proxyPass = "http://127.0.0.1:8082/mcp";
        recommendedProxySettings = true;
        proxyWebsockets = true;
      };

      locations."/logs" = {
        # Strip the /logs prefix explicitly, then proxy without a URI so
        # nginx forwards the rewritten path (e.g. /logs/api/stats -> /api/stats)
        proxyPass = "http://127.0.0.1:8083";
        extraConfig = ''
          rewrite ^/logs/?(.*)$ /$1 break;
        '';
        recommendedProxySettings = true;
        proxyWebsockets = true;
      };

      # Redirect bare /logs to /logs/ so relative URLs resolve inside the app
      locations."= /logs" = {
        return = "301 /logs/";
      };
    };
  };
}
