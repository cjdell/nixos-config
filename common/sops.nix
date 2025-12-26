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
      immich_db_password = { };
      grafana_oidc_client_secret = {
        owner = config.systemd.services.grafana.serviceConfig.User;
      };
    };
  };

  system.activationScripts.sopsNixKey = ''
    mkdir -p  /var/lib/sops-nix
    chmod 500 /var/lib/sops-nix
    chmod 400 /var/lib/sops-nix/key.txt
  '';
}
