{ config, pkgs, ... }:

{
  virtualisation.podman = {
    enable = true;
    autoPrune.enable = true;
    dockerCompat = true;
    dockerSocket.enable = true;
    defaultNetwork.settings.dns_enabled = true;
  };

  virtualisation.oci-containers.backend = "podman";

  environment.systemPackages = with pkgs; [
    podman-compose
  ];
}
