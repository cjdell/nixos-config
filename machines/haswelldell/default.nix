{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./3d.nix
  ];

  networking.hostName = "haswelldell-nixos"; # Define your hostname.
}
