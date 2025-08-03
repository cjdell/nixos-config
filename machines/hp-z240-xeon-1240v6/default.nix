{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = "hp-z240-xeon-1240v6-nixos"; # Define your hostname.
}
