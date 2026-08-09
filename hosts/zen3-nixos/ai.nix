{
  lib,
  pkgs,
  specialArgs,
  ...
}:

{
  environment.systemPackages = with pkgs; [
    rocmPackages.rocminfo
    rocmPackages.amdsmi
  ];

  # I think stable-diffusion-webui needs this
  systemd.tmpfiles.rules = [
    "L+    /opt/rocm   -    -    -     -    ${pkgs.rocmPackages.clr}"
  ];

  systemd.services.llama-swap = {
    description = "Llama Swap";
    after = [ "wait-for-network.service" ];
    wants = [ "wait-for-network.service" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      HSA_OVERRIDE_GFX_VERSION = "9.0.0";
    };

    serviceConfig =
      let
        llama-cpp-cpu = specialArgs.inputs.llama-cpp.packages.${pkgs.stdenv.hostPlatform.system}.default;
        llama-cpp-vulkan = specialArgs.inputs.llama-cpp.packages.${pkgs.stdenv.hostPlatform.system}.vulkan;
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

            "cpu" = {
              cmd = "${llamaCmdCpu} --models-dir /home/cjdell/Models --ctx-size 262144 --metrics --reasoning-preserve";
            };

            "vulkan" = {
              cmd = "${llamaCmdVulkan} --models-dir /home/cjdell/Models --ctx-size 262144 --metrics --reasoning-preserve";
            };

            "rocm" = {
              cmd = "${llamaCmdRocm} --models-dir /home/cjdell/Models --ctx-size 262144 --metrics --reasoning-preserve";
            };
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
}
