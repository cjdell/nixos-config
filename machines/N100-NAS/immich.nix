{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

{
  services.immich = {
    enable = true;
    host = "0.0.0.0";
    port = 2283;
    accelerationDevices = null;
    database = {
      enable = false;
    };
    mediaLocation = "/samsung-4tb/ds-photos/immich";
    openFirewall = true;
  };
  
  system.activationScripts.immich-dir = ''
    mkdir -p /samsung-4tb/ds-photos/immich
    chown immich:immich /samsung-4tb/ds-photos/immich
  '';

  users.users.immich.extraGroups = [
    "video"
    "render"
  ];
}
