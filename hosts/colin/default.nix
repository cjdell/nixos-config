# colin — ported verbatim from the standalone ~/nixos-config flake
# (ElectroNerds home server, 192.168.178.10). This host keeps its own
# nixos-25.11 pin and module set; it is deliberately NOT built through
# mkHost/common/system.nix yet so adoption does not change its role.
# Secrets are the one fleet convention it does follow (sops, see ./sops.nix).
{ sops-nix_25_11, ... }:

[
  sops-nix_25_11.nixosModules.sops
  ./sops.nix

  ./services

  ./configuration.nix
  ./containers.nix
  ./hardware-configuration.nix
  ./http.nix
  ./networking.nix
  ./wireguard.nix
]
