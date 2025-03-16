
{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = "haswellatx-nixos"; # Define your hostname.
}
