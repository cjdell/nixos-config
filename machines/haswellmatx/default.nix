{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = "haswellmatx-nixos"; # Define your hostname.
}
