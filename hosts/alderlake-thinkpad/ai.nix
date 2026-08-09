{
  lib,
  pkgs,
  specialArgs,
  ...
}:

{
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

        llamaCmdCpu = "${llama-cpp-cpu}/bin/llama-server --host 127.0.0.1 --port \${PORT} -t 16 --log-prompts-dir /home/cjdell/nixos-config/llama-logs --verbose -lv 5";
        llamaCmdVulkan = "${llama-cpp-vulkan}/bin/llama-server --host 127.0.0.1 --port \${PORT} -t 12 -ngl all --log-prompts-dir /home/cjdell/nixos-config/llama-logs --verbose -lv 5";

        modelsPath = "/home/cjdell/Models";

        # Native Nix structure representing the YAML config
        llamaConfig = {
          models = {
            "cpu" = {
              cmd = "${llamaCmdCpu} --models-dir /home/cjdell/Models --ctx-size 262144 --metrics --reasoning-preserve";
            };

            "vulkan" = {
              cmd = "${llamaCmdVulkan} --models-dir /home/cjdell/Models --ctx-size 262144 --metrics --reasoning-preserve";
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
