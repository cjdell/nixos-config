# kabylakeitx-nixos — Kaby Lake ITX desktop (i7-7700 4c/8t, 32 GiB,
# RTX 2060 6 GB Turing), 192.168.49.55. Converted 2026-11-03 from the legacy
# inline module list in flake.nix + machines/kabylakeitx. The module set is
# the same one that was inlined there — full desktop, NFS, no-sleep, Sunshine
# with NVENC — the one behavioural change being folding@home: the
# linuxserver *container* (whose image on this box was 14 months old) is
# replaced by the fleet's native v8 client, ./folding.nix.
#
# mkHost (flake.nix) already supplies common/system.nix, users/cjdell,
# home-manager + homeManagerPrefs and commonModules, and sets
# networking.hostName from the directory name — so this file is only the
# host's own imports.
#
# Hardware notes (./hardware-configuration.nix): the RTX 2060 runs the open
# kernel modules of nvidiaPackages.latest, and that package carries the local
# patchelf-0.19.2 re-patch of the driver's bin/ programs — without it
# nvidia-smi segfaults on every call (AGENTS.md, "patchelf 0.19.2 breaks
# NVIDIA and CUDA binaries"). Networking is systemd-networkd, not
# NetworkManager: ./networking.nix builds the br0 bridge (with the MAC the
# router's lease for .55 is pinned to) and slaves en* into it.
{ ... }:

[
  ./folding.nix
  ./hardware-configuration.nix
  ./networking.nix

  ../../common/desktop.nix
  ../../common/nfs.nix
  ../../common/nosleep.nix
  ../../common/sunshine.nix
  ../../common/sunshine-nvidia.nix
]
