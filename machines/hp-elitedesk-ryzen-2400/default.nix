{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = "hp-elitedesk-ryzen-2400-nixos"; # Define your hostname.
}
