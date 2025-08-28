{ config, pkgs, ... }:

{
  imports = [
    ./backup-host.nix
    ./backup.nix
    ./containers.nix
    ./hardware-configuration.nix
    ./networking.nix
    ./nfs.nix
    ./samba.nix
    ./scrutiny.nix
    ./wireguard.nix
  ];

  networking.hostName = "GEN8-NAS"; # Define your hostname.
}
