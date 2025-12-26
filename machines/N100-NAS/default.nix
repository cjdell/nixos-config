{ config, pkgs, ... }:

{
  imports = [
    ./backup.nix
    ./containers.nix
    ./filebrowser.nix
    ./hardware-configuration.nix
    ./immich.nix
    ./jellyfin.nix
    ./monitoring.nix
    ./networking.nix
    ./nfs.nix
    ./postgres.nix
    ./samba.nix
    ./scrutiny.nix
    ./wireguard.nix
  ];

  networking.hostName = "N100-NAS"; # Define your hostname.

  system.autoRollback.enable = true;
}
