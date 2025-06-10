{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./wireguard.nix
  ];

  networking.hostName = "rocketlakelatitude-nixos"; # Define your hostname.
}
