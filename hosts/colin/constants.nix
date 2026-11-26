## Create the initial directories for containers
# nix eval -f home-server/constants.nix CREATE_SRV_SCRIPT --raw | sudo bash

## Create the database need for PhotoPrism
# nix eval -f home-server/constants.nix CREATE_DB_SCRIPT --raw | bash

let
  constants = {
    # HOST_NAME is not here: the host name is mkHost's (flake.nix module
    # `{ networking.hostName = "colin"; }`), which must match hosts/colin.
    LAN_IP = "192.168.178.10";

    SSID = "ElectroNerds Upstairs";

    BASE_DOMAIN = "electronerds.com";

    # Secrets (Route53 credentials, Wi-Fi AP passphrase, WireGuard private key,
    # Tailscale auth key, nginx htpasswd) live in sops, not here:
    #   hosts/colin/secrets/secrets.yaml
    # See hosts/colin/sops.nix.

    ADMIN_UID = 1001;

    RENDER_GID = 303;

    # Port / UID for apps (usually the same for both)
    WHOOGLE = 8001; # Needs to run as root for some reason
    FILE_BROWSER = 8002; # Uses Admin UID
    AD_GUARD = 8003;
    LIBRESPEED = 8004;
    BITTORRENT = 8005;
    UNIFI = 8007;
    JELLYFIN = 8096;
    HOME_ASSISTANT = 8123;

    CREATE_SRV_SCRIPT = ''
      mkdir -p /srv/adguard/conf
      mkdir -p /srv/adguard/work
      chown -R ${toString constants.AD_GUARD}       /srv/adguard

      mkdir -p /srv/bittorrent/config
      chown -R ${toString constants.BITTORRENT}     /srv/bittorrent

      mkdir -p /srv/filebrowser/config
      chown -R ${toString constants.ADMIN_UID}      /srv/filebrowser

      mkdir -p /srv/homeassistant/config
      chown -R ${toString constants.HOME_ASSISTANT} /srv/homeassistant

      mkdir -p /srv/home-page
      chown -R ${toString constants.ADMIN_UID}      /srv/home-page

      mkdir -p /srv/jellyfin/config
      chown -R ${toString constants.JELLYFIN}       /srv/jellyfin

      mkdir -p /srv/unifi
      chown -R ${toString constants.UNIFI}          /srv/unifi

      chown -R :users /srv
      chmod -R g+rw   /srv
    '';
  };
in
constants
