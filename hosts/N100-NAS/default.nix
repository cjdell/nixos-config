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
  # ./immich.nix
  ./immich-container.nix
  ./jellyfin.nix
  ./monitoring.nix
  ./networking.nix
  ./nfs.nix
  ./postgres.nix
  ./samba.nix
  ./scrutiny.nix
  ./tailscale.nix

  ({ config, ... }: {
    system.autoRollback.enable = true;

    sops = {
      secrets = {
        immich_db_password = { };
        immich_oidc_client_secret = { };
        grafana_oidc_client_secret = {
          owner = config.systemd.services.grafana.serviceConfig.User;
        };
        filebrowser_oidc_client_secret = { };
        tailscale_pre_auth_key = { };

        # Jellyfin LDAP plugin config (Kanidm bind credentials). Deployed by
        # the jellyfin-ldap-config systemd service (see jellyfin.nix).
        jellyfin_ldap_auth = {
          sopsFile = ../../secrets/jellyfin_ldap_auth.env;
          format = "dotenv";
          key = ""; # whole file
        };
      };
    };
  })
]
