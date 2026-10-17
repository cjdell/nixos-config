{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [ sops ];

  environment.variables = {
    SOPS_AGE_KEY_FILE = config.sops.age.keyFile;
  };

  environment.sessionVariables = {
    SOPS_AGE_KEY_FILE = config.sops.age.keyFile;
  };

  sops = {
    age.keyFile = "/var/lib/sops-nix/key.txt";
    defaultSopsFile = ../secrets/secrets.yaml;
    secrets = {
      # Brave Search API key, read by the brave-search MCP server that
      # opencode spawns as cjdell (BRAVE_API_KEY_FILE in
      # users/cjdell/opencode.nix). cjdell is in wheel on every host, so
      # 0440 root:wheel is enough — no world-readable key file in $HOME.
      brave_api_key = {
        group = "wheel";
        mode = "0440";
      };
    };
  };

  system.activationScripts.sopsNixKey = ''
    mkdir -p  /var/lib/sops-nix
    chmod 500 /var/lib/sops-nix
    chmod 400 /var/lib/sops-nix/key.txt
  '';
}
