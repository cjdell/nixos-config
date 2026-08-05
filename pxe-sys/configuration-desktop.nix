{
  config,
  pkgs,
  ...
}:

let
  #   # nfsPath = "pxe-server-squashfs"; # NFS share that will host this configuration

  #   # Login script - runs when user logs in
  #   loginScript = pkgs.writeScript "pam-login" ''
  #     #!/bin/sh

  #     # Available variables from PAM:
  #     # PAM_USER - username
  #     # PAM_RHOST - remote host (for SSH)
  #     # PAM_SERVICE - service name (sshd, login, etc)
  #     # PAM_TTY - terminal
  #     # PAM_TYPE - session open/close

  #     logger "PAM Login: user=$PAM_USER service=$PAM_SERVICE from=$PAM_RHOST"
  #     logger "whoami=$(whoami)"

  #     # Get user info
  #     USER_HOME=$(getent passwd "$PAM_USER" | cut -d: -f6)
  #     USER_UID=$(id -u "$PAM_USER")
  #     USER_GID=$(id -g "$PAM_USER")

  #     # Mount NFS share for user
  #     MOUNT_POINT="$USER_HOME/Filestore"

  #     # Create mount point if it doesn't exist
  #     if [ ! -d "$MOUNT_POINT" ]; then
  #       logger "MKDIR"
  #       mkdir -p "$MOUNT_POINT"
  #     fi

  #     # Mount SMB share
  #     logger "MOUNTING USER_HOME=$USER_HOME MOUNT_POINT=$MOUNT_POINT USER_UID=$USER_UID USER_GID=$USER_GID"

  #     logger "mount -t cifs -o user=hackspacer,pass=caffeine1234,uid=$USER_UID,gid=$USER_GID //10.3.1.6/filestore $MOUNT_POINT"

  #     mount -t cifs -o user=hackspacer,pass=caffeine1234,uid=$USER_UID,gid=$USER_GID //10.3.1.6/filestore $MOUNT_POINT

  #     logger "DONE MOUNT"

  #     exit 0
  #   '';

  #   # Logout script - runs when user logs out
  #   logoutScript = pkgs.writeScript "pam-logout" ''
  #     #!/bin/sh

  #     logger "PAM Logout: user=$PAM_USER service=$PAM_SERVICE"

  #     # Get user info
  #     USER_HOME=$(getent passwd "$PAM_USER" | cut -d: -f6)
  #     MOUNT_POINT="$USER_HOME/Filestore"

  #     # Unmount SMB share
  #     if mountpoint -q "$MOUNT_POINT"; then
  #       # Check if any processes are using the mount
  #       if ! fuser -m "$MOUNT_POINT" 2>/dev/null; then
  #         umount "$MOUNT_POINT" 2>/dev/null

  #         if [ $? -eq 0 ]; then
  #           logger "PAM Logout: Unmounted SMB share for $PAM_USER"
  #         else
  #           logger "PAM Logout: Failed to unmount SMB share for $PAM_USER"
  #         fi
  #       else
  #         logger "PAM Logout: Cannot unmount $MOUNT_POINT - still in use by $PAM_USER"
  #       fi
  #     fi

  #     exit 0
  #   '';
  sddm-astronaut = (
    pkgs.sddm-astronaut.override {
      embeddedTheme = "japanese_aesthetic"; # or any other theme
      themeConfig = {
        # Customize colors and settings
        HeaderTextColor = "#d5c4a1";
        Background = "Backgrounds/your-custom-background.png";
        # ... other theme configuration options
      };
    }
  );
  # .overrideAttrs
  #   (oldAttrs: {
  #     # Optional: Inject custom background image
  #     installPhase = oldAttrs.installPhase + ''
  #       chmod u+w $out/share/sddm/themes/sddm-astronaut-theme/Backgrounds/
  #       cp ${./relative/path/to/your-custom-background.png} \
  #         $out/share/sddm/themes/sddm-astronaut-theme/Backgrounds/your-custom-background.png
  #     '';
  #   });
in
{
  networking.hostName = "pxeclient";

  systemd.sleep.settings.Sleep = {
    AllowSuspend = "no";
    AllowHibernation = "no";
    AllowHybridSleep = "no";
    AllowSuspendThenHibernate = "no";
  };

  boot.kernelParams = [
    "mitigations=off"
    "plymouth.use-simpledrm"
    "quiet"
  ];

  boot.plymouth = {
    enable = true;
    theme = "solar";
    logo = ./leigh-logo.png;
  };

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  systemd.services.immediate-shutdown = {
    description = "Immediate Shutdown Script";

    before = [
      "shutdown.target"
      "reboot.target"
      "halt.target"
    ];

    requiredBy = [
      "halt.target"
      "reboot.target"
      "shutdown.target"
    ];

    unitConfig = {
      DefaultDependencies = "no";
    };

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.writeShellScriptBin "immediate-shutdown" "echo b > /proc/sysrq-trigger"}/bin/immediate-shutdown";
    };

    enable = true;
  };

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    extraPackages = with pkgs; [
      intel-media-driver # LIBVA_DRIVER_NAME=iHD
      intel-vaapi-driver # LIBVA_DRIVER_NAME=i965 (older but works better for Firefox/Chromium)
      libvdpau-va-gl
    ];
  };

  hardware.firmware = [ pkgs.linux-firmware ];

  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  services.xserver = {
    enable = true;
    # Configure keymap in X11
    xkb = {
      layout = "gb";
      variant = "";
    };
  };

  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
  };

  # Enable the KDE Plasma Desktop Environment.
  services.desktopManager.plasma6.enable = true;
  # services.desktopManager.gnome.enable = true;

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
    hostKeys = [
      {
        bits = 256;
        path = "/var/secrets/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];
  };

  system.activationScripts.addHostKey = ''
    mkdir -p /var/secrets
    cat ${./ssh_host_ed25519_key} > /var/secrets/ssh_host_ed25519_key
    chmod 0400 /var/secrets/ssh_host_ed25519_key
  '';

  programs.firefox.enable = true;

  programs.nix-ld.enable = true;

  # Set your time zone.
  time.timeZone = "Europe/London";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_GB.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_GB.UTF-8";
    LC_IDENTIFICATION = "en_GB.UTF-8";
    LC_MEASUREMENT = "en_GB.UTF-8";
    LC_MONETARY = "en_GB.UTF-8";
    LC_NAME = "en_GB.UTF-8";
    LC_NUMERIC = "en_GB.UTF-8";
    LC_PAPER = "en_GB.UTF-8";
    LC_TELEPHONE = "en_GB.UTF-8";
    LC_TIME = "en_GB.UTF-8";
  };

  # Configure console keymap
  console.keyMap = "uk";

  fileSystems."/home" = {
    fsType = "nfs4";
    device = "192.168.49.23:/sas-24tb/ds-home";
    options = [
      "vers=4.2"
      "rsize=1048576"
      "hard"
      "nocto"
      "noatime"
      "actimeo=86400"
      "_netdev"
      "nconnect=16"
      "noacl"
      "fsc"
      "lookupcache=all"
      "actimeo=86400"
      "nolock"
    ];
  };

  # Allow the user to log in as root without a password.
  users.users.root.initialHashedPassword = "$y$j9T$tJbN4/phKGK0iVkqCiCzL.$SIsr7MfC4tlcs.urJKDlU2kadGzpHhxikwj3hNiR555";

  users.users.cjdell = {
    uid = 1234;
    isNormalUser = true;
    description = "Chris Dell";
    extraGroups = [
      "networkmanager"
      "wheel"
      "render"
      "video"
    ];
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCbDJ7tQwODw2kx2f1bstOUElKnaR3hP2RbwCsf6zebZ5n/1CFUoM2Ye78D/IG/6kgDc22wD9EkzyvIwF/96fp3IgxK5ja/Q0pEhbd8xAPGIpFC7BUyePqozRusSvJXl7RamBb8lgsjySQxJxYX9MQzbQkfasWOwWE+WWqiC9nwk6WiER7EraOdEVNNF9cuNS/LVFrQZG5xdzI5gSgaxth2kQSgE3z7jIIvmlYkChEjTMXSQt9MrluhWB1nzGDHVrcqW8uu/jAqeMhRCXP39wtmL21v3WFn1jwDQlOgbR1CxnBzy+jE62TqvOJg8x6/J2WC/VXcdndHq1vKYP0s5mQn cjdell@gmail.com"
    ];
    initialHashedPassword = "$y$j9T$tJbN4/phKGK0iVkqCiCzL.$SIsr7MfC4tlcs.urJKDlU2kadGzpHhxikwj3hNiR555";
  };

  # Don't require sudo/root to `reboot` or `poweroff`.
  security.polkit.enable = true;

  # Allow passwordless sudo from nixos user
  security.sudo = {
    enable = true;
    wheelNeedsPassword = false;
  };

  environment.systemPackages = with pkgs; [
    sddm-astronaut

    openldap # for ldapsearch
    google-chrome
    vscode
    freecad
  ];

  security.pki.certificates = [
    # leighhack.org (Root CA)
    ''
      -----BEGIN CERTIFICATE-----
      MIIFszCCA5ugAwIBAgIUX837VWcgZbwRrjZcPAlmqI3n0UYwDQYJKoZIhvcNAQEL
      BQAwYTELMAkGA1UEBhMCR0IxEDAOBgNVBAgMB0VuZ2xhbmQxDjAMBgNVBAcMBUxl
      aWdoMRgwFgYDVQQKDA9MZWlnaCBIYWNrc3BhY2UxFjAUBgNVBAMMDWxlaWdoaGFj
      ay5vcmcwHhcNMjUxMTE3MTIzMzUxWhcNMzUxMTE1MTIzMzUxWjBhMQswCQYDVQQG
      EwJHQjEQMA4GA1UECAwHRW5nbGFuZDEOMAwGA1UEBwwFTGVpZ2gxGDAWBgNVBAoM
      D0xlaWdoIEhhY2tzcGFjZTEWMBQGA1UEAwwNbGVpZ2hoYWNrLm9yZzCCAiIwDQYJ
      KoZIhvcNAQEBBQADggIPADCCAgoCggIBAKlLpuU7rHkb2gZBhr3QXrdwxPlU4bcm
      ZHNsjbLVS3zgm7QzahvLJWlZN9d+Hw8EzrY9+DoCNNb2DSfJno4LMGeRweT6hXct
      HTel160nuP3DxIxVHHwaNczBCgX4Db7CX1zpf2ppQ/Ya2n7Gy7lGkNo1RxbBhKeL
      PfIauCKso96AXLUDA1shX2+WiYPI04VkuuBZ+x33oHNWtptvpCcCII8JRh9zeNYY
      fqZQgKDXMvrHZ51xAR6og+lzsBlNomR/43e40OAPhfWDPyCxQnQ3DlTi+3CHO1tn
      JLowzmiOGUoVNe+J9ymBR3032AWPiU7RBVnGSs+noCv7YYPQP301Etq2miIMAkHG
      ngEQtqlZvB5dNusjPAUC2oQMEs4I2PCO9I9B+Ty88bev6KfgIMBUiDtBEk/cDmcg
      kC/pGsrw9LycNx8P7Oo/nLmTj0uq7etPE4iNpr0rzqhoHwufrutEVxBP5mAqF9vT
      Oi3lUTm3LMkgFsT0+MOMyc/EupgdSLpVw6duDBu4U/MOMbj7r/k/LKcrXS5d7rhL
      JbWYPXM2VqhZpqmdgf6hEAxoJSJ+Q/ulvlDHFtzDkk7Vz1SFDCcNUpgqHIrMTMJT
      veIGWQwCqnvEbl7s8AKufZyVZJc8ssX5K/LUBmghBUHcDK9UpsPE7hm4ZdVIIN+b
      a2WYvUAEI3Z3AgMBAAGjYzBhMB8GA1UdIwQYMBaAFBiU7GgfN3KVXhUw84CcHuXo
      F5rEMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMB0GA1UdDgQWBBQY
      lOxoHzdylV4VMPOAnB7l6BeaxDANBgkqhkiG9w0BAQsFAAOCAgEApzU6uSLXxwlG
      5YGjSo+OOeskP5jtu6tFBIgaFNw4e+br0OlLWg58S44h7e+h6EtlN6WqEjwzPpn2
      HvIgttfNg6x7s3LziEzFwy7SXtADfWd3nPEMXqL3KuDY3F3BsNFBksumEObB5Rfj
      ZXZwlIROEtWRlKq12ZVTJ7/PnHAQAnhbhPrSrywmRqV2r+Dq7nEQveiyv7nCm/HC
      eGp9uNzXI2eHedfhB3+8ySeyvU/QpG0c2MFNgOmkJnTPaXVvZ8xDpGn1cMVV6dh5
      AYqSIHkSN4Ti/wzaeDRa8bBpiBkpDC2rXjYkNHQKCa+YhhxL7950sYWOOrfdQUEO
      1JFIjFUAPptH7PJTv47YRYlu+4V+K61E4CJ4Q6J6cvovE1lzbPew/yWjKM4BIF8g
      I1InwoAiVtDHvj9z195iWAiEI/mNM44Cfq5f/Uy1yGAp4RZnZJl8y85DNPrbustE
      FsPYfcUxyNDcmMlz6PC447SFXCkZStPuxNFgXqPGjfA/WFICVLR4JwTl2kukMHwr
      sv9KWeuPrR0N06pq+f6aa9OLb4lIQrJqTy7//ATWbvxJd43eNEb1h/QnGo2vrI5F
      n+wBP1b8SdE9kW7e4Utse42wIH47f1oME+dauBNolawDO9rT9lzoDW1oc7dgivrW
      fBbCwgkaci4r5pMqKjOy7DHKcoQRerA=
      -----END CERTIFICATE-----
    ''
  ];

  ## Test with:
  # ldapsearch -x -b "dc=ldap,dc=goauthentik,dc=io" -H ldap://10.3.1.36 -D "cn=pgina,dc=ldap,dc=goauthentik,dc=io" -W

  # services.sssd = {
  #   enable = true;
  #   config = ''
  #     [sssd]
  #     config_file_version = 2
  #     services = nss, pam
  #     domains = authentik
  #     debug_level = 6

  #     [nss]
  #     filter_users = root,nixbld
  #     filter_groups = root,wheel,nixbld
  #     debug_level = 6

  #     [pam]
  #     debug_level = 6

  #     [domain/authentik]
  #     id_provider = ldap
  #     auth_provider = ldap
  #     access_provider = permit

  #     # Connection
  #     ldap_uri = ldaps://authentik.int.leighhack.org
  #     ldap_search_base = dc=ldap,dc=goauthentik,dc=io

  #     # Bind credentials
  #     ldap_default_bind_dn = cn=pgina,ou=users,dc=ldap,dc=goauthentik,dc=io
  #     ldap_default_authtok = pgina

  #     # Search bases
  #     ldap_user_search_base = ou=users,dc=ldap,dc=goauthentik,dc=io
  #     ldap_group_search_base = ou=groups,dc=ldap,dc=goauthentik,dc=io

  #     # User attributes - matched to Authentik's schema
  #     ldap_user_object_class = user
  #     ldap_user_name = cn
  #     ldap_user_uid_number = uidNumber
  #     ldap_user_gid_number = gidNumber
  #     ldap_user_home_directory = homeDirectory
  #     ldap_user_shell = loginShell
  #     ldap_user_gecos = displayName

  #     # CRITICAL: Provide default shell since Authentik doesn't set loginShell
  #     default_shell = /run/current-system/sw/bin/bash
  #     fallback_homedir = /home/%u

  #     # Group attributes
  #     ldap_group_object_class = group
  #     ldap_group_name = cn
  #     ldap_group_gid_number = gidNumber
  #     ldap_group_member = member

  #     # Schema
  #     ldap_schema = rfc2307bis
  #     ldap_id_mapping = false

  #     # Don't query rootDSE anonymously
  #     ldap_disable_rootdse = true

  #     # TLS settings
  #     ldap_id_use_start_tls = true
  #     ldap_tls_reqcert = demand
  #     ldap_tls_cacert = /etc/static/pki/tls/certs/ca-bundle.crt

  #     # Timeouts
  #     ldap_network_timeout = 5
  #     ldap_opt_timeout = 5

  #     # Caching
  #     cache_credentials = true
  #     enumerate = false
  #   '';
  # };

  # security.pam.services = {
  #   sddm = {
  #     makeHomeDir = true;
  #     text = ''
  #       # Account management.
  #       account include login # login (order 10100)

  #       # Authentication management.
  #       auth substack login # login (order 10100)

  #       # Password management.
  #       password substack login # login (order 10100)

  #       # Session management.
  #       session include login # login (order 10100)

  #       #### The above is the default. Below we are adding ####

  #       session optional ${pkgs.pam}/lib/security/pam_exec.so stdout seteuid type=open_session ${loginScript}
  #       session optional ${pkgs.pam}/lib/security/pam_exec.so stdout seteuid type=close_session ${logoutScript}
  #     '';
  #   };

  #   login.makeHomeDir = true;
  #   sshd.makeHomeDir = true;
  # };

  # Keep local users working
  users.mutableUsers = true;

  # Give sudo access to anyone in the Infra LDAP group
  security.sudo.extraRules = [
    {
      groups = [
        "infra"
        "Infra"
      ]; # SSSD will lowercase it
      commands = [
        {
          command = "ALL";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  environment.plasma6.excludePackages = [ pkgs.kdePackages.baloo ];

  system.stateVersion = config.system.nixos.release;
}
