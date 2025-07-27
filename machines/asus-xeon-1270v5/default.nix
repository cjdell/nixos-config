{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = "asus-xeon-1270v5-nixos"; # Define your hostname.
}
