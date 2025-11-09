{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = "macbook-pro-2009-nixos"; # Define your hostname.
}
