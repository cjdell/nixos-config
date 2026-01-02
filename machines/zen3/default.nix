{ config, pkgs, ... }:

{
  imports = [
    # ./ai.nix
    ./hardware-configuration.nix
  ];

  networking.hostName = "zen3-nixos"; # Define your hostname.
}
