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
    defaultSopsFile = ./secrets/secrets.yaml;
    secrets = {
      # Brave Search API key for the brave-search MCP server in opencode
      # (users/cjdell/opencode.nix); same secret as the shared secrets.yaml,
      # but the router keeps its own sops file. 0440 root:wheel so the MCP
      # server, run by cjdell (in wheel), can read it.
      brave_api_key = {
        group = "wheel";
        mode = "0440";
      };
      aws_access_key_secret = { };
      pppoe_password = { };
      wireguard_key = { };
      home_assistant_header = { };
      home_assistant_token = { };
      nginx_sso_client_secret = { };
      plausible_secret_key = { };
      headscale_secret = {
        owner = "headscale";
      };
      headscale_api_key = {
        owner = "headscale";
      };
      headscale_pre_auth_key = {
        owner = "headscale";
      };
      tailscale_pre_auth_key = { };
      leigh_hackspace_tailscale_pre_auth_key = { };
      # Router -> grafton-hackspace-client key used by hackspace-tunnel-check to
      # ask the VM which layer is down (root in there is password-only, and
      # cjdell's agent keys are not available to a systemd service).
      grafton_hackspace_client_ssh_key = { };
      borg_backup_key = { };
      frigate_whisper_db_password = { };
      # Fixed sshd host key for the grafton-hackspace-client microVM (mounted
      # into the VM's /run/secrets; baked into /var/secrets at activation).
      vm_host_key = { };
    };
  };
}
