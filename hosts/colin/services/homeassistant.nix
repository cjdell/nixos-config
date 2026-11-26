{ pkgs, ... }:

let
  constants = import ../constants.nix;
in
{
  users.users.homeassistant = {
    uid = constants.HOME_ASSISTANT;
    group = "users";
    isNormalUser = true;
  };

  virtualisation.oci-containers.containers = {
    homeassistant = {
      hostname = "homeassistant";
      image = "linuxserver/homeassistant";
      autoStart = true;
      volumes = [
        "/srv/homeassistant/config:/config"
      ];
      environment = {
        TZ = "Europe/London";
        PUID = "${toString constants.HOME_ASSISTANT}";
        PGID = "100";
      };
      extraOptions = [
        "--network=host"
        "--dns=127.0.0.1"
      ];
    };
  };

  # journalctl -u homeassistant-hacs-install -b
  systemd.services.homeassistant-hacs-install =
    let
      homeassistant-hacs = (
        pkgs.writeShellScriptBin "homeassistant-hacs" ''
          ${pkgs.coreutils-full}/bin/sleep 5

          ${pkgs.wget}/bin/wget -O /srv/homeassistant/hacs.zip https://github.com/hacs/integration/releases/latest/download/hacs.zip
          rm -rf /srv/homeassistant/config/custom_components/hacs
          mkdir -p /srv/homeassistant/config/custom_components/hacs
          ${pkgs.unzip}/bin/unzip /srv/homeassistant/hacs.zip -d /srv/homeassistant/config/custom_components/hacs
          rm /srv/homeassistant/hacs.zip
        ''
      );
    in
    {
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];

      before = [ "podman-homeassistant.service" ];
      wantedBy = [ "podman-homeassistant.service" ];
      requiredBy = [ "podman-homeassistant.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${homeassistant-hacs}/bin/homeassistant-hacs";

        User = "homeassistant";
        Group = "users";
      };
    };

  services.nginx.virtualHosts = {
    "homeassistant.${constants.BASE_DOMAIN}" = {
      serverAliases = [ "homeassistant.www.${constants.BASE_DOMAIN}" ];
      useACMEHost = "${constants.BASE_DOMAIN}";
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString constants.HOME_ASSISTANT}";
        recommendedProxySettings = true;
        proxyWebsockets = true;
      };
    };
  };
}
