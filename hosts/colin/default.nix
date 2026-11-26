# colin — the ElectroNerds home server (192.168.178.10), adopted into the
# fleet on 2026-11-26.
#
# Since the last unification step it is built by flake.nix's `mkHost`, so the
# fleet module set comes from there, not from this file:
#   - common/system.nix      (fleet CLI set, openssh, nix-ld, sudo, locale,
#                             stateVersion 24.11, firewall off, mitigations=off)
#   - common/build-client.nix (switched OFF below — see the comment)
#   - users/cjdell           (the cjdell account + home-manager)
#   - commonModules          (nixos-utils rollback + containers modules)
#   - home-manager + its fleet defaults (homeManagerPrefs)
#
# What stays here is what makes colin different.
{ sops-nix, ... }:

[
  # sops-nix's module is not part of mkHost (each host pulls it from the flake
  # inputs), and hosts/colin/sops.nix needs it.
  sops-nix.nixosModules.sops

  # THE ONE HOST THAT MUST NOT USE THE FLEET BUILDER. colin sits on
  # 192.168.178.0/24 behind TalkTalk: it cannot reach zen3 over the LAN or the
  # tailnet (zen3 has no tailnet node), so a build-machine entry would only add
  # a failed ssh-ng attempt per build before falling back. It builds locally
  # (4 cores — raise --max-jobs only if you really want to sit and wait).
  { fleetBuildClient.enable = false; }

  # Remote safety net (the module itself comes from commonModules): after every
  # activation, roll back and reboot unless `sudo nixos-confirm` disarms it.
  ./rollback.nix

  ./services

  ./configuration.nix
  ./containers.nix
  ./hardware-configuration.nix
  ./http.nix
  ./networking.nix
  ./wireguard.nix

  ./sops.nix
]
