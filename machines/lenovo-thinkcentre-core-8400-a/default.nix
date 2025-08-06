{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = "lenovo-thinkcentre-core-8400-a-nixos"; # Define your hostname.
}
