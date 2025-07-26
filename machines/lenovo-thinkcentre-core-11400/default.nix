{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = "lenovo-thinkcentre-core-11400-nixos"; # Define your hostname.
}
