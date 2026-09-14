{ pkgs, ... }:

let
  # Own host user for the container (the UID == service-port convention used by
  # immich/jellyfin/fah on this host). The container runs with PUID/PGID below,
  # so the files it writes are owned by this user.
  QBITTORRENT_UID = 8081;

  # qBittorrent has no native OIDC, so to run it behind the router's nginx-sso
  # gate with a single login (SSO in front, qBittorrent's own login skipped)
  # this seeds two things:
  #
  #  - Host header validation off: qBittorrent rejects Host values it doesn't
  #    recognise ("Invalid Host header") — the proxy sends
  #    Host: qbittorrent.home.chrisdell.info.
  #  - Auth bypass for 192.168.49.1 (the router, which is where proxied
  #    requests come from) so Kanidm SSO is the only login for the proxied
  #    URL. Accessing this host's 192.168.49.22:8081 directly still uses
  #    qBittorrent's own username/password.
  #
  # Seeded on first run only (the activation script never overwrites an
  # existing file), so later WebUI changes survive rebuilds.
  #
  # NOTE: backslash is literal inside a Nix '' string — write config keys with
  # a single `\`, NOT `\\`. Doubled backslashes are not recognised as keys and
  # qBittorrent silently drops them when it rewrites the file on first start.
  seedConfig = pkgs.writeText "qbittorrent.conf" ''
    [LegalNotice]
    Accepted=true

    [Preferences]
    WebUI\Address=*
    WebUI\Port=8081
    WebUI\HostHeaderValidation=false
    WebUI\AuthSubnetWhitelistEnabled=true
    WebUI\AuthSubnetWhitelist=192.168.49.1/32
  '';
in
{
  # journalctl -u podman-qbittorrent -f
  # The WebUI's temporary first-run password is logged there too.
  virtualisation.oci-containers.containers.qbittorrent = {
    hostname = "qbittorrent";
    image = "linuxserver/qbittorrent:latest";
    autoStart = true;
    ports = [
      # LinuxServer images want the WebUI on the *same* port inside and out
      # (the CSRF check uses the port), hence 8081:8081 + WEBUI_PORT below.
      # This is what the router's nginx proxies to.
      "8081:8081"
      # Torrenting (active node). Inert until the router forwards these.
      "6881:6881"
      "6881:6881/udp"
    ];
    volumes = [
      "/srv/qbittorrent/config:/config"
      "/samsung-4tb/ds-media/Downloads:/downloads"
    ];
    environment = {
      TZ = "Europe/London";
      PUID = toString QBITTORRENT_UID;
      PGID = "100"; # group `users`
      UMASK = "002"; # group-writable, so cjdell can manage the downloads too
      WEBUI_PORT = "8081";
      TORRENTING_PORT = "6881";
    };
  };

  users.users.qbittorrent = {
    uid = QBITTORRENT_UID;
    group = "users";
    isNormalUser = true;
  };

  # Config + download directories, owned by the qbittorrent user. On first
  # switch/boot seed the config (see seedConfig above); the existence check
  # means WebUI changes survive rebuilds.
  system.activationScripts.qbittorrent = ''
    install -d -m 0755 -o ${toString QBITTORRENT_UID} -g 100 /srv/qbittorrent/config
    install -d -m 0755 -o ${toString QBITTORRENT_UID} -g 100 /srv/qbittorrent/config/qBittorrent
    install -d -m 0775 -o ${toString QBITTORRENT_UID} -g 100 /samsung-4tb/ds-media/Downloads
    if [ ! -e /srv/qbittorrent/config/qBittorrent/qBittorrent.conf ]; then
      install -m 0644 -o ${toString QBITTORRENT_UID} -g 100 ${seedConfig} /srv/qbittorrent/config/qBittorrent/qBittorrent.conf
    fi
  '';
}
