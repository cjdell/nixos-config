{ config, pkgs, ... }:

{
  imports = [
    ./containers.nix
    ./hardware-configuration.nix
    ./networking.nix
    ./nfs.nix
    ./samba.nix
    ./scrutiny.nix
    # ./wireguard.nix
  ];

  networking.hostName = "N100-NAS"; # Define your hostname.
}
