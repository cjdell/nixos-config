pxe-server:
{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    (import ./pxe-server.nix pxe-server)
  ];

  networking.hostName = "precision-nixos"; # Define your hostname.
}
