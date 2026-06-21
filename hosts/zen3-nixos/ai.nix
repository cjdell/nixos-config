{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    rocmPackages.rocminfo
  ];

  # I think stable-diffusion-webui needs this
  systemd.tmpfiles.rules = [
    "L+    /opt/rocm   -    -    -     -    ${pkgs.rocmPackages.clr}"
  ];

  ## NOTES: Get the container image...
  # cd ~/Projects/LLM/llama.cpp/
  # podman build -t llama-cpp-vulkan --target server -f .devops/vulkan.Dockerfile .
  # podman save llama-cpp-vulkan -o llama-cpp-vulkan.tar
  # sudo podman load -i llama-cpp-vulkan.tar
  # rm llama-cpp-vulkan.tar

  # View logs with: journalctl -u podman-qwen-8b -f
  virtualisation.oci-containers.containers = {
    qwen-8b = {
      hostname = "qwen-8b";
      image = "llama-cpp-vulkan";
      cmd = [
        "--jinja"
        "--chat-template-file"
        "/llama.cpp/models/templates/qwen3-workaround.jinja"
        "-m"
        "/llama.cpp/models/Qwen_Qwen3-8B-Q6_K_L.gguf"
        "-ngl"
        "1000"
        "--ctx-size"
        "0"
        "--port"
        "8080"
        "--slots"
        "--metrics"
      ];
      autoStart = true;
      ports = [
        "8080:8080"
      ];
      volumes = [
        "/home/cjdell/Projects/LLM/llama.cpp:/llama.cpp:Z"
      ];
      environment = {
        TZ = "Europe/London";
      };
      extraOptions = [
        "--device=/dev/dri/renderD128"
        "--device=/dev/dri/card1"
      ];
    };
  };
}
