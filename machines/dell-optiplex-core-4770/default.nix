{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./3d.nix
  ];

  networking.hostName = "dell-optiplex-core-4770-nixos"; # Define your hostname.
}
