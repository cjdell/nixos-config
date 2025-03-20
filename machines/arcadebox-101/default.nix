{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./wireguard.nix
  ];

  networking.hostName = "arcadebox-101"; # Define your hostname.
}
