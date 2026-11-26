{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

let
  constants = import ../constants.nix;
  RENDER_GID = "303";
in
{
  users.users.librespeed = {
    uid = constants.LIBRESPEED;
    group = "users";
    isNormalUser = true;
  };

  virtualisation.oci-containers.containers = {
    librespeed = {
      hostname = "librespeed";
      image = "ghcr.io/librespeed/speedtest:latest";
      autoStart = true;
      ports = [
        "${toString constants.LIBRESPEED}:80"
      ];
      environment = {
        TZ = "Europe/London";
        # The ghcr.io/librespeed/speedtest image defaults WEBPORT to 8080,
        # while the publish below (and nginx) speak to container port 80. Left
        # alone, apache listened on 8080 and speed.electronerds.com was a 502
        # (found while verifying the unification activation on 2026-11-26).
        WEBPORT = "80";
      };
    };
  };

  services.nginx.virtualHosts = {
    "speed.${constants.BASE_DOMAIN}" = {
      serverAliases = [ "speed.www.${constants.BASE_DOMAIN}" ];
      useACMEHost = "${constants.BASE_DOMAIN}";
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString constants.LIBRESPEED}";
        recommendedProxySettings = true;
        proxyWebsockets = true;
      };
    };
  };
}
