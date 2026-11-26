# colin — ported verbatim from the standalone ~/nixos-config flake
# (ElectroNerds home server, 192.168.178.10). This host keeps its own
# nixos-25.11 pin and module set; it is deliberately NOT built through
# mkHost/common/system.nix yet so adoption does not change its role.
# Secrets are the one fleet convention it does follow (sops, see ./sops.nix).
# Since 2026-11-26 it also runs the fleet rollback module (./rollback.nix) as
# the remote-host safety net; that is the one shared module it imports so far.
# The sops module is chosen in flake.nix alongside the nixpkgs pin, because
# sops-install-secrets must match the toolchain (the 25.11 pin needs the
# pre-Go-1.26 sops-nix, the fleet pin needs the current one).
{ nixos-utils, ... }:

[
  ./sops.nix

  nixos-utils.nixosModules.rollback
  ./rollback.nix

  ./services

  ./configuration.nix
  ./containers.nix
  ./hardware-configuration.nix
  ./http.nix
  ./networking.nix
  ./wireguard.nix
]
