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
    ./tailscale.nix
  ];

  networking.hostName = "GEN8-NAS"; # Define your hostname.

  environment.systemPackages = with pkgs; [
    lsiutil
    sasutils
  ];

  sops = {
    secrets = {
      tailscale_pre_auth_key = { };
    };
  };
}
