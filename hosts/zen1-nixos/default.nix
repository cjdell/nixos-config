# zen1-nixos — Zen 1 desktop (AMD), 192.168.49.51.
# Converted 2026-10-20 from the legacy inline config in flake.nix +
# machines/zen1. mkHost (flake.nix) supplies common/system.nix, users/cjdell,
# home-manager and commonModules; this file only adds what is host-specific.
{ sops-nix, ... }:

[
  ../../common/desktop.nix
  ((import ../../common/folding-at-home.nix) "amd")
  ../../common/nfs.nix
  ../../common/nosleep.nix
  ../../common/sunshine.nix
  ../../common/system.nix
  # sops: provides /run/secrets/brave_api_key for the brave-search MCP server
  # that users/cjdell/opencode.nix spawns (see common/sops.nix).
  sops-nix.nixosModules.sops
  ../../common/sops.nix
  # ../../common/wine.nix
  ../../users/cjdell

  ./hardware-configuration.nix
]
