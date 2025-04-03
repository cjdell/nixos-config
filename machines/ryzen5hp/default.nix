{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = "ryzen5hp-nixos"; # Define your hostname.
}
