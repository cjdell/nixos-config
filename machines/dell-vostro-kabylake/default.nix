{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = "dell-vostro-kabylake-nixos"; # Define your hostname.

  # programs.coolercontrol = {
  #   enable = true;
  #   nvidiaSupport = true;
  # };
}
