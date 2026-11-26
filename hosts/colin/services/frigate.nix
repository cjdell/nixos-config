{ config, pkgs, ... }:

let
  constants = import ../constants.nix;
  FRIGATE_UID = 8971;
in
{
  users.users.frigate = {
    uid = FRIGATE_UID;
    group = "users";
    isNormalUser = true;
  };

  boot.kernel.sysctl = {
    "kernel.perf_event_paranoid" = 0;
  };

  # journalctl -u podman-frigate -f
  virtualisation.oci-containers.containers = {
    frigate = {
      hostname = "frigate";
      image = "ghcr.io/blakeblackshear/frigate:stable";
      autoStart = true;
      volumes = [
        "/electronerds/ds-cameras/storage:/media/frigate"
        "/electronerds/ds-cameras/config:/config"
      ];
      ports = [
        "8971:5000" # Insecure
        # "8971:8971" # Secure
        "1984:1984" # go2rtc admin panel
        "8554:8554"
        "8555:8555/tcp"
        "8555:8555/udp"
      ];
      environment = {
        FRIGATE_RTSP_PASSWORD = "password";
      };
      extraOptions = [
        "--mount=type=tmpfs,destination=/tmp/cache,tmpfs-size=1000000000"
        "--device=/dev/dri/renderD128"
        "--shm-size=1024m"
        "--cap-add=CAP_PERFMON"
        "--privileged"
      ];
    };
  };

  system.activationScripts.frigate = ''
    # Create config and storage directories
    mkdir -p /electronerds/ds-cameras/storage
    mkdir -p /electronerds/ds-cameras/config

    # Ensure correct permissions
    chown -R ${toString FRIGATE_UID}:users  /electronerds/ds-cameras
    chmod -R g+rw                           /electronerds/ds-cameras
  '';

  services.nginx.virtualHosts = {
    "cameras.${constants.BASE_DOMAIN}" = {
      useACMEHost = "${constants.BASE_DOMAIN}";
      forceSSL = true;

      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString FRIGATE_UID}";
        recommendedProxySettings = true; 
        proxyWebsockets = true;
      };

      extraConfig = ''
        auth_basic_user_file ${config.sops.templates."htpasswd".path};

        if ($internal = 0) {
          # rewrite ^ /go-away;
          set $auth_basic Restricted;
        }
        if ($internal = 1) {
          set $auth_basic off;
        }

        auth_basic $auth_basic;
      '';
    };
  };
}
