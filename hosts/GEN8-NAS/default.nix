{ sops-nix, ... }:

[
  sops-nix.nixosModules.sops

  ../../common/nosleep.nix
  ../../common/sops.nix

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

  ({ pkgs, ... }: {
    environment.systemPackages = with pkgs; [
      lsiutil
      sasutils
    ];

    sops = {
      secrets = {
        tailscale_pre_auth_key = { };
      };
    };
  })
]
