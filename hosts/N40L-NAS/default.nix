{ sops-nix, disko-zfs, ... }:

[
  sops-nix.nixosModules.sops
  disko-zfs.nixosModules.default

  ../../common/nosleep.nix
  ../../common/sops.nix
  ../../common/zfs-status.nix

  ./backup-host.nix
  ./containers.nix
  ./hardware-configuration.nix
  ./monitoring.nix
  ./networking.nix
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

    services.zfsStatus = {
      enable = true;
    };
  })
]
