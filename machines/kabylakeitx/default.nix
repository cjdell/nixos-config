
{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = "kabylakeitx-nixos"; # Define your hostname.
}
