{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = "coffeelakedell-nixos"; # Define your hostname.

  # programs.coolercontrol = {
  #   enable = true;
  #   nvidiaSupport = true;
  # };
}
