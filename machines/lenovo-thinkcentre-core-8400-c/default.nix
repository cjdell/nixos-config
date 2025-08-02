{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = "lenovo-thinkcentre-core-8400-c-nixos"; # Define your hostname.
}
