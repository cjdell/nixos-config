let
  RENDER_GID = "303";
  JELLYFIN_UID = 8096;
in
{
  virtualisation.oci-containers.containers = {
    jellyfin = {
      hostname = "jellyfin";
      # Pinned to a specific Jellyfin version. "latest" caused an unexpected
      # major upgrade which raced with the plugin auto-update and broke LDAP auth.
      image = "linuxserver/jellyfin:10.11.11";
      autoStart = true;
      ports = [
        "8096:8096"
        "7359:7359/udp"
      ];
      volumes = [
        "/srv/jellyfin/config:/config"
        "/samsung-4tb/ds-media:/Media:ro"
      ];
      environment = {
        TZ = "Europe/London";
        PUID = toString JELLYFIN_UID;
        PGID = "100";
      };
      extraOptions = [
        "--device=/dev/dri/renderD128"
        "--group-add=${RENDER_GID}"
      ];
    };
  };

  users.users.jellyfin = {
    uid = JELLYFIN_UID;
    group = "users";
    isNormalUser = true;
  };

  system.activationScripts.jellyfin = ''
    # Create config and storage directories
    mkdir -p /srv/jellyfin/config

    # Ensure correct permissions
    chown -R ${toString JELLYFIN_UID}:users /srv/jellyfin
    chmod -R g+rw /srv/jellyfin
  '';

  # Deploy the LDAP plugin config from the sops secret (Kanidm bind password).
  # The plugin stores its settings in the container volume and they were wiped
  # once before, so this makes the config declarative and idempotent.
  # NOTE: the deployed config is authoritative - changes made in the Jellyfin
  # plugin UI are overwritten on the next switch/boot. Edit this file instead.
  systemd.services.jellyfin-ldap-config = {
    description = "Install Jellyfin LDAP plugin configuration";
    wantedBy = [ "podman-jellyfin.service" ];
    before = [ "podman-jellyfin.service" ];
    wants = [ "sops-install-secrets.service" ];
    after = [ "sops-install-secrets.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
            set -euo pipefail

            secret=/run/secrets/jellyfin_ldap_auth
            if [[ ! -f "$secret" ]]; then
              echo "jellyfin-ldap-config: secret not available yet, skipping" >&2
              exit 0
            fi

            bind_password=$(grep '^JELLYFIN_LDAP_BIND_PASSWORD=' "$secret" | cut -d= -f2-)
            if [[ -z "$bind_password" ]]; then
              echo "jellyfin-ldap-config: bind password missing from secret" >&2
              exit 1
            fi

            mkdir -p /srv/jellyfin/config/data/plugins/configurations

            cat > /srv/jellyfin/config/data/plugins/configurations/LDAP-Auth.xml <<XML
      <?xml version="1.0" encoding="utf-8"?>
      <PluginConfiguration xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
        <LdapUsers>
          <LdapUser>
            <LinkedJellyfinUserId>5fc88b4f-23f3-461d-a2fb-9a40eb361294</LinkedJellyfinUserId>
            <LdapUid>cjdell</LdapUid>
            <ProfileImageHash />
          </LdapUser>
        </LdapUsers>
        <LdapServer>kanidm.home.chrisdell.info</LdapServer>
        <LdapPort>8998</LdapPort>
        <UseSsl>true</UseSsl>
        <UseStartTls>false</UseStartTls>
        <SkipSslVerify>false</SkipSslVerify>
        <LdapBindUser>cjdell@kanidm.home.chrisdell.info</LdapBindUser>
        <LdapBindPassword>''${bind_password}</LdapBindPassword>
        <LdapBaseDn>dc=kanidm,dc=home,dc=chrisdell,dc=info</LdapBaseDn>
        <LdapSearchFilter>(uid={username})</LdapSearchFilter>
        <LdapAdminBaseDn />
        <LdapAdminFilter>(&amp;(uid={username})(memberof=spn=admins@kanidm.home.chrisdell.info,dc=kanidm,dc=home,dc=chrisdell,dc=info))</LdapAdminFilter>
        <EnableLdapAdminFilterMemberUid>false</EnableLdapAdminFilterMemberUid>
        <LdapSearchAttributes>uid, cn, mail, displayName</LdapSearchAttributes>
        <LdapClientCertPath />
        <LdapClientKeyPath />
        <LdapRootCaPath />
        <CreateUsersFromLdap>true</CreateUsersFromLdap>
        <AllowPassChange>false</AllowPassChange>
        <LdapUidAttribute>uid</LdapUidAttribute>
        <LdapUsernameAttribute>cn</LdapUsernameAttribute>
        <LdapPasswordAttribute>userPassword</LdapPasswordAttribute>
        <EnableLdapProfileImageSync>false</EnableLdapProfileImageSync>
        <RemoveImagesNotInLdap>false</RemoveImagesNotInLdap>
        <LdapProfileImageAttribute>jpegphoto</LdapProfileImageAttribute>
        <LdapProfileImageFormat>Default</LdapProfileImageFormat>
        <EnableAllFolders>false</EnableAllFolders>
        <EnabledFolders />
        <PasswordResetUrl />
      </PluginConfiguration>
      XML

            chown jellyfin:users /srv/jellyfin/config/data/plugins/configurations/LDAP-Auth.xml
            chmod 664 /srv/jellyfin/config/data/plugins/configurations/LDAP-Auth.xml
    '';
  };
}
