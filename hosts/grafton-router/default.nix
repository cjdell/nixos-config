{
  nixos-utils,
  sops-nix,
  ...
}:

[
  ../../utils/oci.nix
  ../../common/dsh-web-service.nix

  nixos-utils.nixosModules.rollback
  nixos-utils.nixosModules.containers
  nixos-utils.nixosModules.notifications
  nixos-utils.nixosModules.health

  sops-nix.nixosModules.sops

  ./networking
  ./services
  ./virtual-machines

  ./containers.nix
  ./configuration.nix
  # The forked DeepSeek Harness Web GUI (common/dsh-web-service.nix), served
  # on 192.168.49.1:3080 — see docs/dsh-fork/.
  ./dsh-harness.nix
  ./hardware-configuration.nix
  ./http.nix
  ./sops.nix
]
