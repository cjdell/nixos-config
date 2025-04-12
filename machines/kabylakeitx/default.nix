{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./networking.nix
  ];

  networking.hostName = "kabylakeitx-nixos"; # Define your hostname.
}
