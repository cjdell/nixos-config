{
  ...
}:

# Open WebUI: a browser UI over the litellm proxy, for checking the model
# groups work without writing an agent client.
#
# Plumbing: browser -> open-webui :8080 -> litellm :4000/v1 -> llama-swap
# -> llama.cpp. It is NOT routed through nginx: open-webui's frontend uses
# absolute API paths (/api, /static), so prefix proxying (like /recallium/)
# would break it - it listens directly on 0.0.0.0:8080 instead.
#
# First visit creates the admin account (WEBUI_AUTH defaults to on); users
# and chats live in /var/lib/open-webui (StateDirectory, dynamic user).
{
  services.open-webui = {
    enable = true;
    host = "0.0.0.0";
    port = 8080;

    environment = {
      # The one OpenAI-compatible upstream: litellm. Master key is the same
      # plaintext one as in litellm.yaml (no sops on this host).
      OPENAI_API_BASE_URLS = "http://127.0.0.1:4000/v1";
      OPENAI_API_KEYS = "sk-cd6fb8f9f282b660fbd3cfed670ac97eab1412cd8eb3f002";
      OPENAI_API_TITLES = "Local LiteLLM";

      # Everything goes through litellm; don't probe an Ollama server.
      ENABLE_OLLAMA_API = "False";

      # Make links/opensearch point at the LAN address rather than localhost.
      WEBUI_URL = "http://192.168.49.50:8080";
    };
  };

  # Start once litellm (and thus llama-swap) is up.
  systemd.services.open-webui = {
    after = [ "litellm.service" ];
    wants = [ "litellm.service" ];
  };
}
