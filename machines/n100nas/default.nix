{ config, pkgs, ... }:

{
  imports = [
    ./containers.nix
    ./hardware-configuration.nix
    ./networking.nix
    ./nfs.nix
    ./samba.nix
    ./scrutiny.nix
    ./wireguard.nix
  ];

  networking.hostName = "n100nas"; # Define your hostname.
}
