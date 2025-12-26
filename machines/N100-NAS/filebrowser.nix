{
  config,
  pkgs,
  ...
}:

let
  FILE_BROWSER_PORT = 8002; # Uses Admin UID
in
{
  # journalctl -u podman-filebrowser -f
  # sudo podman exec -ti filebrowser /bin/sh
  virtualisation.oci-containers.containers = {
    filebrowser = {
      hostname = "filebrowser";
      image = "gtstef/filebrowser";
      autoStart = true;
      ports = [
        "${toString FILE_BROWSER_PORT}:8080"
      ];
      volumes = [
        "/samsung-4tb/ds-media:/storage/ds-media"
        "/srv/filebrowser/config:/home/filebrowser/data"
        "/srv/filebrowser/cache:/home/filebrowser/cache"
      ];
      environment = {
        TZ = "Europe/London";
        UMASK = "002";
        FILEBROWSER_CONFIG = "data/config.yaml";
        # FILEBROWSER_ADMIN_PASSWORD = "admin";
      };
      extraOptions = [
        "--user=${toString config.users.users.cjdell.uid}:100" # Use Admin UID as we need full filesystem permissions
      ];
    };
  };

  system.activationScripts.filebrowser-init =
    let
      fileBrowserConfig = pkgs.writeText "filebrowser-config" (
        builtins.toJSON {
          server = {
            port = 8080;
            baseURL = "/";
            logging = [ { levels = "info|warning|error"; } ];
            sources = [ { path = "/storage"; } ];
            database = "data/database.db"; # Path in container: /home/filebrowser/data/database.db
            cacheDir = "/home/filebrowser/cache";
          };

          auth = {
            methods = {
              oidc = {
                enabled = true;
                clientId = "filebrowser";
                clientSecret = "AvSaKbQEZ2GdXK7WzBCqy8ghQU6RHyZpbZupbgpJaAXPvMvf"; # Use environment variable
                issuerUrl = "https://kanidm.home.chrisdell.info/oauth2/openid/filebrowser";
                scopes = "email openid profile groups";
                userIdentifier = "preferred_username";
                createUser = true;
                adminGroup = "admins@kanidm.home.chrisdell.info";
              };
            };
          };

          userDefaults = {
            preview = {
              image = true;
              popup = true;
              video = false;
              office = false;
              highQuality = false;
            };
            darkMode = true;
            disableSettings = false;
            singleClick = false;
            permissions = {
              admin = false;
              modify = false;
              share = false;
              api = false;
            };
          };
        }
      );
    in
    "cp ${fileBrowserConfig} /srv/filebrowser/config/config.yaml";

  # Ensure directories exist and have correct ownership
  systemd.tmpfiles.rules = [
    "d /srv/filebrowser/config 0755 ${toString config.users.users.cjdell.uid} ${toString config.users.groups.users.gid} -"
    "d /srv/filebrowser/cache  0755 ${toString config.users.users.cjdell.uid} ${toString config.users.groups.users.gid} -"
  ];
}
