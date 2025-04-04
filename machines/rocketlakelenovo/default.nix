{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = "rocketlakelenovo-nixos"; # Define your hostname.
}
