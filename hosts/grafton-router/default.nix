{
  nixos-utils,
  sops-nix,
  home-manager,
  ...
}:

[
  ../../utils/oci.nix
  # zen3-nixos as this machine's remote Nix build server, local builds as
  # fallback (the router carries its own module set, so it does not get
  # common/system.nix and imports the client module directly).
  ../../common/build-client.nix
  ../../common/dsh-web-service.nix

  nixos-utils.nixosModules.rollback
  nixos-utils.nixosModules.containers
  nixos-utils.nixosModules.notifications
  nixos-utils.nixosModules.health

  sops-nix.nixosModules.sops
  home-manager.nixosModules.home-manager

  ./networking
  ./services
  ./virtual-machines

  ./containers.nix
  ./configuration.nix
  # The forked DeepSeek Harness Web GUI (common/dsh-web-service.nix), served
  # on 192.168.49.1:3080 — see docs/dsh-fork/.
  ./dsh-harness.nix
  # cjdell's home profile: just the fleet opencode config
  # (users/cjdell/opencode.nix) — the router has no desktop home.nix.
  ./home-manager.nix
  ./hardware-configuration.nix
  ./http.nix
  ./sops.nix
]
