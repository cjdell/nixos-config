{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./3d.nix
    ./klipper-firmware.nix
  ];

  networking.hostName = "3d-printer-server"; # Define your hostname.
}
