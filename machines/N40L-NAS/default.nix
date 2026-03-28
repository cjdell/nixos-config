{ config, pkgs, ... }:

{
  imports = [
    ./backup-host.nix
    ./backup.nix
    ./containers.nix
    ./hardware-configuration.nix
    ./monitoring.nix
    ./networking.nix
    ./nfs.nix
    ./samba.nix
    ./scrutiny.nix
  ];

  networking.hostName = "N40L-NAS"; # Define your hostname.
}
