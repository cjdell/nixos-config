{ config, ... }:

{
  imports = [
    ./backup.nix
    ./containers.nix
    ./filebrowser.nix
    ./hardware-configuration.nix
    ./immich.nix
    ./jellyfin.nix
    ./monitoring.nix
    ./networking.nix
    ./nfs.nix
    ./postgres.nix
    ./samba.nix
    ./scrutiny.nix
    ./tailscale.nix
  ];

  networking.hostName = "N100-NAS"; # Define your hostname.

  system.autoRollback.enable = true;

  sops = {
    secrets = {
      immich_db_password = { };
      grafana_oidc_client_secret = {
        owner = config.systemd.services.grafana.serviceConfig.User;
      };
      tailscale_pre_auth_key = { };
    };
  };
}
