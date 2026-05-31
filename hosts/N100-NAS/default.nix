{ sops-nix, ... }:

[
  sops-nix.nixosModules.sops

  ((import ../../common/folding-at-home.nix) "none")

  ../../common/nosleep.nix
  ../../common/sops.nix

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

  (
    { config, ... }:
    {
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
  )
]
