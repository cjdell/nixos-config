{
  lib,
  pkgs,
  ...
}:

{
  # LiteLLM: one OpenAI-compatible endpoint for every local LLM class.
  #
  # Model groups (scouting / planning / coding / creative / uncensored) live in
  # ./litellm.yaml, which the unit references by literal repo path so group
  # changes only need `sudo systemctl restart litellm` - no rebuild (and the
  # master key never lands in the Nix store). The proxy fronts llama-swap's
  # per-GPU routers (127.0.0.1:8081/upstream/{vega,r9700}/v1), which auto-load
  # GGUF models from /home/cjdell/Models on demand (see ./litellm.yaml).
  #
  # Hosts without sops keep plaintext secrets here (same as ai.nix).
  systemd.services.litellm = {
    description = "LiteLLM proxy";
    after = [
      "llama-swap.service"
      "wait-for-network.service"
    ];
    wants = [ "wait-for-network.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      ExecStart = "${lib.getExe pkgs.litellm} --config /home/cjdell/nixos-config/hosts/zen3-nixos/litellm.yaml --port 4000 --host 0.0.0.0";
      Restart = "always";
      RestartSec = 3;
    };
  };

  # The CLI ships with the package anyway; handy for testing config changes on
  # a scratch port (e.g. `litellm --config litellm.yaml --port 4001`).
  environment.systemPackages = with pkgs; [ litellm ];

  # Expose the proxy via nginx as well as the direct :4000 port. /v1 and
  # /health go to litellm; everything else (/, /ui, /logs, /mcp, /recallium*)
  # keeps routing to llama-swap and the containers as before.
  services.nginx.virtualHosts."192.168.49.50" = {
    locations."/v1" = {
      proxyPass = "http://127.0.0.1:4000";
      recommendedProxySettings = true;
      proxyWebsockets = true;
      extraConfig = ''
        # SSE streaming litellm -> llama-swap -> llama.cpp must not be buffered
        proxy_buffering off;
        # Long generations / model loads can exceed the 60s default read timeout.
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
      '';
    };

    locations."/health" = {
      # Prefix match also covers /health/liveliness and /health/readiness.
      proxyPass = "http://127.0.0.1:4000/health";
      recommendedProxySettings = true;
    };
  };
}
