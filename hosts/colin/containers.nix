# Podman for colin. The image-update timer/package is NOT here: the fleet
# modules (nixos-utils system.updateContainers, enabled in common/system.nix)
# provide `update-containers` + its 02:00 timer and notify webhook. This file
# used to carry a hand-rolled copy (Monday 02:00, `podman pull` + restart
# podman-*); with both imported they collide on the same unit names, so it was
# dropped during the 2026-11-26 unification.
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

{
  virtualisation.podman = {
    enable = true;
    autoPrune.enable = true;
    dockerCompat = true;
    dockerSocket.enable = true;
    # defaultNetwork.settings.dns_enabled = true;
    defaultNetwork.settings.ipv6_enabled = true;
  };

  virtualisation.containers.containersConf.settings.containers.umask = "0002";

  virtualisation.oci-containers.backend = "podman";
}
