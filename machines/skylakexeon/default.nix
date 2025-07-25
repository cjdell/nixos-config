{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = "skylakexeon-nixos"; # Define your hostname.
}
