{
  config,
  pkgs,
  ...
}:

let
  KANIDM_PORT = 8999;
  # 1.10.5 went EOL/insecure in nixpkgs (2026-10-09). Upgraded in place: domain
  # backup taken first, then one minor step 1.10 -> 1.11 (kanidm requires
  # sequential minor upgrades — see book/src/server_updates.md).
  kanidm_pkg = pkgs.kanidm_1_11.withSecretProvisioning;
in
{
  # Grant kanidm access to nginx group for ACME certificates
  users.users.kanidm.extraGroups = [ config.services.nginx.group ];

  # OAuth2 client secret for Silo; kanidm-provision (runs as kanidm) reads it,
  # same shape as container_ui_oidc_client_secret in container-ui.nix.
  sops.secrets.silo_oidc_client_secret = {
    owner = "kanidm";
  };

  # sudo kanidmd recover-account idm_admin
  # kanidm login
  services.kanidm = {
    server.enable = true;
    package = kanidm_pkg;

    provision = {
      enable = true;
      persons = {
        cjdell = {
          present = true;
          displayName = "Chris Dell";
          legalName = "Chris Dell";
          mailAddresses = [ "me@chrisdell.info" ];
        };
        testuser = {
          present = true;
          displayName = "Test User";
          legalName = "Test User";
          mailAddresses = [ "testuser@example.com" ];
        };
        jack = {
          present = true;
          displayName = "Jack";
          legalName = "Jack";
          mailAddresses = [ "jack@chrisdell.info" ];
        };
        deepak = {
          present = true;
          displayName = "Deepak";
          legalName = "Deepak";
        };
      };
      groups = {
        "admins" = {
          present = true;
          members = [
            "cjdell"
            "jack"
          ];
          overwriteMembers = true;
        };
      };
      systems = {
        # kanidm system oauth2 show-basic-secret headscale
        oauth2 = {
          "headscale" = {
            present = true;
            public = false;
            displayName = "Headscale";
            originUrl = [
              "https://tailscale.home.chrisdell.info/oidc/callback"
              "https://tailscale.home.chrisdell.info/admin/oidc/callback"
            ];
            originLanding = "https://tailscale.home.chrisdell.info/admin";
            preferShortUsername = true;
            scopeMaps = {
              "admins" = [
                "email"
                "openid"
                "profile"
                "groups"
              ];
            };
            allowInsecureClientDisablePkce = true;
          };
          "home-assistant" = {
            present = true;
            public = false;
            displayName = "Home Assistant";
            originUrl = "https://home.chrisdell.info/auth/oidc/callback";
            originLanding = "https://home.chrisdell.info";
            preferShortUsername = true;
            scopeMaps = {
              "admins" = [
                "email"
                "openid"
                "profile"
                "groups"
              ];
            };
          };
          # kanidm system oauth2 show-basic-secret grafana
          "grafana" = {
            present = true;
            public = false;
            displayName = "Grafana";
            originUrl = "https://grafana.home.chrisdell.info";
            originLanding = "https://grafana.home.chrisdell.info/login/generic_oauth";
            preferShortUsername = true;
            scopeMaps = {
              "admins" = [
                "email"
                "openid"
                "profile"
                "groups"
              ];
            };
            claimMaps = {
              grafana_role = {
                joinType = "array";
                valuesByGroup = {
                  admins = [ "GrafanaAdmin" ];
                };
              };
            };
          };
          # kanidm system oauth2 show-basic-secret filebrowser
          "filebrowser" = {
            present = true;
            public = false;
            displayName = "File Browser";
            originUrl = "https://filebrowser.home.chrisdell.info/api/auth/oidc/callback";
            originLanding = "https://filebrowser.home.chrisdell.info/api/auth/oidc/login";
            preferShortUsername = true;
            scopeMaps = {
              "admins" = [
                "email"
                "openid"
                "profile"
                "groups"
              ];
            };
            allowInsecureClientDisablePkce = true;
          };
          # kanidm system oauth2 show-basic-secret immich
          "immich" = {
            present = true;
            public = false;
            displayName = "Immich";
            originUrl = [
              "https://immich.home.chrisdell.info/auth/login"
              "app.immich:///oauth-callback"
            ];
            originLanding = "https://immich.home.chrisdell.info/auth/login?autoLaunch=1";
            preferShortUsername = true;
            scopeMaps = {
              "admins" = [
                "email"
                "openid"
                "profile"
                "groups"
              ];
            };
            claimMaps = {
              immich_role = {
                joinType = "array";
                valuesByGroup = {
                  admins = [ "admin" ];
                  # users = [ "user" ];
                };
              };
            };
          };
          # kanidm system oauth2 show-basic-secret nginx-sso
          "nginx-sso" = {
            present = true;
            public = false;
            displayName = "NGINX SSO";
            originUrl = "https://nginx-sso.home.chrisdell.info/login";
            originLanding = "https://nginx-sso.home.chrisdell.info";
            preferShortUsername = true;
            scopeMaps = {
              "admins" = [
                "email"
                "openid"
                "profile"
                "groups"
              ];
            };
            allowInsecureClientDisablePkce = true;
          };
          "container-ui" = {
            present = true;
            public = false;
            displayName = "Container UI";
            originUrl = "https://containers.home.chrisdell.info/oidc/callback";
            originLanding = "https://containers.home.chrisdell.info";
            basicSecretFile = config.sops.secrets.container_ui_oidc_client_secret.path;
            preferShortUsername = true;
            scopeMaps = {
              "admins" = [
                "email"
                "openid"
                "profile"
                "groups"
              ];
            };
          };
          # Kanidm OIDC sign-in for Silo (silo-plugin-auth-oidc on N100-NAS,
          # hosts/N100-NAS/silo.nix).
          # ⚠ originUrl MUST match Silo's callback URI exactly:
          #   https://silo.home.chrisdell.info/api/v2/auth/oauth/5/callback
          # The `5` is Silo's OIDC installation id, minted when the plugin was
          # first enabled (2026-11-21; shown on Silo's Sign-in settings page).
          # Reinstalling the plugin mints a NEW id — update this line then, or
          # logins fail with a redirect_uri mismatch. Kanidm refuses
          # plain-http redirect URIs, which is why
          # Silo is reached through the router's silo.home.chrisdell.info vhost
          # (http.nix) instead of http://192.168.49.22:8090.
          # In the plugin: issuer https://kanidm.home.chrisdell.info/oauth2/openid/silo,
          # client id silo, secret from /run/secrets/silo_oidc_client_secret
          # (sops: silo_oidc_client_secret), groups scope ON, admin groups =
          # admins (groups arrive as name@domain; the plugin matches the short
          # name). Leave offline access off — see the plugin's Kanidm note.
          "silo" = {
            present = true;
            public = false;
            displayName = "Silo";
            originUrl = "https://silo.home.chrisdell.info/api/v2/auth/oauth/5/callback";
            originLanding = "https://silo.home.chrisdell.info";
            basicSecretFile = config.sops.secrets.silo_oidc_client_secret.path;
            preferShortUsername = true;
            scopeMaps = {
              "admins" = [
                "email"
                "openid"
                "profile"
                "groups"
              ];
            };
          };
        };
      };
      # NOTE: kanidm-provision silently ignores person fields it doesn't know,
      # so the enableUnix flag below is a no-op — cjdell's posixaccount class
      # was actually set by hand. What LDAP-backed apps (Jellyfin's LDAP-Auth
      # plugin on N100-NAS, hosts/N100-NAS/jellyfin.nix) really need per user:
      #  1. class `posixaccount` — the plugin's bind (cjdell) is a unix bind,
      #     which kanidm bounds to the ANONYMOUS identity (process_ldap_uuid_to_
      #     identity), and anonymous may only read posixaccount entries
      #     (idm_acp_all_accounts_posix_read). Without the class the user is
      #     invisible to the plugin's (uid={username}) search.
      #  2. a credential LDAP bind accepts: either a POSIX password (min length
      #     15 — that's what the jellyfin_ldap_auth sops secret holds for
      #     cjdell), or membership of an `account_policy`-classed group with
      #     allow_primary_cred_fallback=true, which makes LDAP bind fall back
      #     to the primary (web) password. `deepak` uses that fallback via the
      #     manually-created `ldap-cred-fallback` group.
      # Set a person's primary password (the withSecretProvisioning patch adds
      # --from-environment; password via KANIDM_RECOVER_ACCOUNT_PASSWORD_FILE):
      #   sudo kanidmd scripting recover-account -c "$(systemctl show kanidm -p ExecStart \
      #     | grep -oE '/nix/store/[a-z0-9]+-server\.toml' | head -1)" <name> --from-environment
      # posix class + fallback-group membership, via PUT/POST on the v1 API
      # with an idm_admin bearer (idm_admin's primary is regenerated randomly
      # by the module on every kanidm start, so script it: recover-account
      # idm_admin, then POST /v1/auth init2→begin→cred for the bearer token):
      #   POST /v1/person/<n>/_attr/class   body ["posixaccount"]
      #   POST /v1/group/ldap-cred-fallback/_attr/member   body ["<n>@kanidm.home.chrisdell.info"]
      extraJsonFile = pkgs.writeText "kanidm_extra" (
        builtins.toJSON {
          persons.cjdell.enableUnix = true;
        }
      );
    };

    server.settings = {
      bindaddress = "127.0.0.1:${toString KANIDM_PORT}";
      ldapbindaddress = "0.0.0.0:${toString 8998}";

      tls_chain = "/var/lib/acme/chrisdell.info/fullchain.pem";
      tls_key = "/var/lib/acme/chrisdell.info/key.pem";

      domain = "kanidm.home.chrisdell.info";
      origin = "https://kanidm.home.chrisdell.info";

      online_backup = {
        schedule = "00 00 * * 1";
        versions = 7;
      };
    };
  };

  # ldapsearch -H ldaps://kanidm.home.chrisdell.info:8998 -x '(name=cjdell@kanidm.home.chrisdell.info)' '*'
  # ldapsearch -H ldaps://kanidm.home.chrisdell.info:8998 -x -b "dc=kanidm,dc=home,dc=chrisdell,dc=info" "(objectClass=*)"
  # ldapsearch -H ldaps://kanidm.home.chrisdell.info:8998 -x -b "dc=kanidm,dc=home,dc=chrisdell,dc=info" -D "cjdell@kanidm.home.chrisdell.info" -W "(objectClass=*)"
  # ldapsearch -H ldaps://kanidm.home.chrisdell.info:8998 -x -b "dc=kanidm,dc=home,dc=chrisdell,dc=info" -D "cjdell@kanidm.home.chrisdell.info" -W "(uid=cjdell)" cn mail uid
  # ldapwhoami -H ldaps://kanidm.home.chrisdell.info:8998 -x -D "cjdell@kanidm.home.chrisdell.info" -W

  environment.systemPackages = with pkgs; [
    kanidm_pkg
    openldap
  ];

  environment.variables = {
    KANIDM_URL = "https://kanidm.home.chrisdell.info";
    KANIDM_NAME = "idm_admin";
  };

  # The kanidm module won't let us set the db_path directly.
  systemd.services.kanidm.serviceConfig.BindPaths = [
    "/srv/kanidm:/var/lib/kanidm"
  ];

  services.nginx.virtualHosts = {
    "kanidm.home.chrisdell.info" = {
      useACMEHost = "chrisdell.info";
      forceSSL = true;

      locations."/" = {
        proxyPass = "https://127.0.0.1:${toString KANIDM_PORT}";
        extraConfig = ''
          proxy_ssl_verify off;
          proxy_ssl_server_name on;
          proxy_ssl_name chrisdell.info;
        '';
      };
    };
  };

  system.activationScripts.kanidm = ''
    # Create config directory
    mkdir -p /srv/kanidm

    # Ensure correct permissions
    chown -R kanidm:kanidm /srv/kanidm
    chmod -R g+rwX /srv/kanidm
  '';
}
