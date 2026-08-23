{ lib, pkgs, ... }:

# Ollama-compatible API bridge in front of llama-swap's OpenAI endpoint.
# LEGACY: Recallium no longer uses this — it talks OpenAI directly to the
# /recallium-llm nginx proxy (see recalliumGpu in ./nginx.nix). Kept for any
# Ollama-only client still hitting port 11434; translates Ollama ->
# llama-swap's OpenAI API.

let
  ollama-bridge = pkgs.rustPlatform.buildRustPackage {
    pname = "ollama-bridge";
    version = "0.1.0";
    src = ../../../ollama-bridge;
    cargoLock.lockFile = ../../../ollama-bridge/Cargo.lock;
    doCheck = false;
  };
in
{
  # Must listen on 0.0.0.0 so the rootful podman Recallium container can
  # reach it via host.containers.internal.
  systemd.services.ollama-bridge = {
    description = "Ollama-compatible API bridge to llama-swap";
    after = [
      "llama-swap.service"
      "wait-for-network.service"
    ];
    wants = [ "wait-for-network.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      ExecStart = "${ollama-bridge}/bin/ollama-bridge --listen 0.0.0.0:11434 --upstream http://127.0.0.1:8081/upstream/r9700/v1";
      Restart = "always";
      RestartSec = 3;
    };
  };
}
