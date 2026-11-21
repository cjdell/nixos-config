# Silo media server (silo-server.org) — trial alongside Jellyfin, added
# 2026-11-20/21. Omnibus image: Silo + bundled PostgreSQL (pgvector) + Redis
# in ONE container, so this is a single oci-containers entry.
#
# Sign-in is Kanidm OIDC via the silo-plugin-auth-oidc plugin: the OAuth2
# client is provisioned by hosts/grafton-router/services/kanidm.nix, whose
# originUrl must equal the callback URL Silo prints on its Sign-in settings
# page — that URL embeds an installation id created when the plugin is first
# enabled, so the placeholder there is corrected once by hand.
#
# Ports: 8090 web+API (proxied as https://silo.home.chrisdell.info by the
# router), 8097 the Jellyfin/Emby-compatible API (8096 belongs to the real
# Jellyfin container), 13378 the Audiobookshelf-compatible API.
#
# Updating: upstream is pre-release and `latest` is a moving tag, so the image
# is digest-pinned. Bump = `podman pull ghcr.io/silo-server/silo-server@<new>`
# (or re-tag latest and read .Digest), edit the image line, switch. Back up
# the SECRET_KEY secret and a copy of /srv/silo/config first — migrations are
# not forward-compatible.
{ config, ... }:

let
  SILO_UID = 8090;
  RENDER_GID = "303";
in
{
  virtualisation.oci-containers.containers.silo = {
    hostname = "silo";
    image = "ghcr.io/silo-server/silo-server@sha256:a83816fcef1e9786a6f9d7dc37e06de25e451b11cf24b62e39e30862d91bcb59";
    # The digest must be in the local store before switching (pull it once);
    # a live GHCR pull on every start is not worth the flaky dependency.
    pull = "never";
    autoStart = true;
    ports = [
      "8090:8080"
      "8097:8096"
      "13378:13378"
    ];
    volumes = [
      "/srv/silo/config:/config"
      "/samsung-4tb/ds-media:/mnt/media:ro"
      # Upstream keeps these out of /config so backups stay small.
      "/srv/silo/transcode:/tmp/silo-transcode"
      "/srv/silo/download-artifacts:/tmp/silo-download-artifacts"
      "/srv/silo/catalog-seeds:/catalog-seeds:ro"
    ];
    environment = {
      TZ = "Europe/London";
      PUID = toString SILO_UID;
      # users (100): the group owning ds-media, so the library reads without
      # any ACL work on the ZFS side.
      PGID = "100";
      # Must be the proxy URL: the OIDC plugin builds its callback from it,
      # and Kanidm refuses non-HTTPS redirect URIs.
      SILO_PUBLIC_URL = "https://silo.home.chrisdell.info";
    };
    # SECRET_KEY=... — at-rest encryption key for stored plugin credentials.
    # The whole sops file is dotenv and is consumed as an env file directly.
    environmentFiles = [ config.sops.secrets.silo_env.path ];
    extraOptions = [
      # BBR + TCP send-buffer helper Silo runs at startup; it drops the cap
      # before serving. Without it Silo just logs that it could not tune TCP.
      "--cap-add=NET_ADMIN"
      # The N100 iGPU (QSV/VA-API) — same render node the Jellyfin container uses.
      "--device=/dev/dri/renderD128"
      "--group-add=${RENDER_GID}"
    ];
    # Upstream's stop_grace_period: 2m, so in-flight playback drains.
    stopTimeout = 120;
  };

  users.users.silo = {
    uid = SILO_UID;
    group = "users";
    isNormalUser = true;
  };

  sops.secrets.silo_env = {
    sopsFile = ../../secrets/silo.env;
    format = "dotenv";
    key = ""; # whole file
  };

  # oci-containers units start at multi-user.target, so the ordering is right
  # in practice; stated anyway so a container can never start without its env
  # file (same reasoning as common/folding-at-home-sops.nix).
  systemd.services.podman-silo = {
    wants = [ "sops-install-secrets.service" ];
    after = [ "sops-install-secrets.service" ];
  };

  system.activationScripts.silo = ''
    mkdir -p /srv/silo/config /srv/silo/transcode /srv/silo/download-artifacts /srv/silo/catalog-seeds
    chown -R ${toString SILO_UID}:users /srv/silo
    chmod -R g+rwX /srv/silo
  '';
}
