{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = "coffeelakelenovo-nixos"; # Define your hostname.
}
