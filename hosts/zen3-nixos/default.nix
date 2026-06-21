{ home-manager, ... }:

[
  ../../common/desktop.nix
  ../../common/nfs.nix
  ../../common/nosleep.nix
  ../../common/podman.nix
  ../../common/sunshine.nix
  ../../common/wine.nix

  ((import ../../common/folding-at-home.nix) "amd")

  # ./ai.nix
  ./hardware-configuration.nix
]
