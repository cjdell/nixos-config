{ pkgs, ... }:

{
  imports = [
    ./backup-host.nix
    # ./backup.nix
    ./containers.nix
    ./hardware-configuration.nix
    ./monitoring.nix
    ./networking.nix
    # ./nfs.nix
    # ./samba.nix
    ./scrutiny.nix
    ./tailscale.nix
  ];

  networking.hostName = "N40L-NAS"; # Define your hostname.

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
