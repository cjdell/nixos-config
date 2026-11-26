{ config, lib, pkgs, modulesPath, ... }:

let
  constants = import ../constants.nix;
in
{
  users.users.adguard = {
    uid = constants.AD_GUARD;
    group = "users";
    isNormalUser = true;
  };

  virtualisation.oci-containers.containers = {
    adguard = {
      hostname = "adguard";
      image = "adguard/adguardhome";
      autoStart = true;
      ports = [
        # "${constants.LAN_IP}:53:53/tcp"
        # "${constants.LAN_IP}:53:53/udp"
        # "127.0.0.1:53:53/tcp"
        # "127.0.0.1:53:53/udp"
        "53:53/tcp"
        "53:53/udp"
        "${toString constants.AD_GUARD}:80/tcp"
        "20443:443/tcp"
        "20443:443/udp"
        "23000:3000/tcp"
      ];
      volumes = [
        "/srv/adguard/work:/opt/adguardhome/work"
        "/srv/adguard/conf:/opt/adguardhome/conf"
      ];
      environment = {
        TZ = "Europe/London";
      };
      extraOptions = [
        "--user=${toString constants.AD_GUARD}:100"
      ];
    };
  };

  services.nginx.virtualHosts = {
    "adguard.${constants.BASE_DOMAIN}" = {
      serverAliases = [ "adguard.www.${constants.BASE_DOMAIN}" ];
      useACMEHost = "${constants.BASE_DOMAIN}";
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString constants.AD_GUARD}";
        recommendedProxySettings = true;
      };
    };
  };
}
