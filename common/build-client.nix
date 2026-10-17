# Use zen3-nixos (192.168.49.50) as the fleet's shared Nix build server.
#
# Imported from common/system.nix — which mkHost gives to every hosts/* and
# every legacy machines/* config — and directly by hosts/grafton-router (it
# carries its own module set). The guard below keeps it off zen3-nixos
# itself: the builder must not add itself as a build machine, and zen3's own
# nix.buildMachines entry (hosts/zen3-nixos/default.nix) dispatches
# aarch64-linux to the MacBookAir.
#
# How it works on a client:
#   - nix.distributedBuilds = true makes the daemon use /etc/nix/machines,
#     generated from nix.buildMachines.
#   - speedFactor 4 (local default is 1) sends every build to zen3 while it
#     is healthy; zen3 runs up to 16 jobs.
#   - nix.settings.max-jobs = 1 keeps ONE local build slot enabled, so when
#     zen3 is unreachable the daemon marks it unavailable and falls back to
#     building locally instead of failing. Raise it for a faster fallback
#     (`nixos-rebuild ... --max-jobs 4`) or per host (this is mkDefault).
#
# Requirements on each client (else ssh-ng fails and the host silently
# builds locally, which is the fallback but not the point):
#   - a root key exists:  sudo ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N ''
#   - its PUBLIC key is authorized on zen3, in
#     users.users.root.openssh.authorizedKeys.keys (hosts/zen3-nixos/default.nix).
# Clients connect as root over ssh-ng; root is in zen3's trusted-users.
{ config, lib, ... }:
let
  inherit (lib) mkDefault mkIf;
  isBuilder = config.networking.hostName == "zen3-nixos";
  builderHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFdeRHV02KmEdG3YoH2aq1++9PqeTwGlWUsG0XKzUE27";
in
{
  config = mkIf (!isBuilder) {
    nix.distributedBuilds = true;
    nix.settings.max-jobs = mkDefault 1;
    nix.buildMachines = [
      {
        hostName = "192.168.49.50";
        protocol = "ssh-ng";
        sshUser = "root";
        sshKey = "/root/.ssh/id_ed25519";
        system = "x86_64-linux";
        maxJobs = 16;
        speedFactor = 4;
        supportedFeatures = [
          "nixos-test"
          "benchmark"
          "big-parallel"
        ];
        # Pin the builder's host key in the machines entry itself, so ssh-ng
        # never depends on /etc/ssh/ssh_known_hosts being present yet.
        publicHostKey = builderHostKey;
      }
    ];
    # Same pin for plain ssh(1) (nix copy, manual debugging).
    programs.ssh.knownHosts."zen3-nixos" = {
      hostNames = [
        "192.168.49.50"
        "zen3-nixos"
        "zen3-nixos.grafton.tailscale"
      ];
      publicKey = builderHostKey;
    };
  };
}
