{ config, pkgs, ... }:

{
  imports = [
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
