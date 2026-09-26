{ ... }:

[
  ../../common/desktop.nix
  ../../common/nfs.nix
  ../../common/nosleep.nix
  ../../common/podman.nix
  # ../../common/sunshine.nix
  # ../../common/sunshine-nvidia.nix

  ./hardware-configuration.nix
  ./3d.nix
  ./klipper-firmware.nix
]
