# haswellatx-nixos — Haswell ATX desktop (i5-4460, Radeon R9 290),
# 192.168.49.54. Converted 2026-10-25 from the legacy inline config in
# flake.nix + machines/haswellatx, deliberately kept a BARE-MINIMUM build:
# just enough for a working Plasma desktop, plus the folding@home space
# heater. Deliberately NOT imported here (all available if wanted again):
#   common/desktop.nix  — the full workstation suite (chrome, zed, kate,
#                         furmark, moonlight, remmina, libvirtd/virt-manager,
#                         bluetooth, appimage binfmt, ddcutil, spice)
#   common/sunshine.nix, common/wine.nix, common/nfs.nix
#   (common/nosleep.nix is an empty stub — the real sleep refusal lives in
#   ./folding-heater.nix)
#
# mkHost (flake.nix) supplies common/system.nix, users/cjdell, home-manager
# and commonModules; users/cjdell/nix.nix brings the account, SSH keys,
# auto-login, and (via home.nix) powerdevil auto-suspend=off + no baloo.
{ sops-nix, ... }:

[
  ./folding-heater.nix
  ./hardware-configuration.nix

  # sops: the shared fleet key at /var/lib/sops-nix/key.txt decrypts
  # secrets/fah.yaml (the FAH account token, ./folding-heater.nix) and
  # secrets/secrets.yaml (brave_api_key for users/cjdell/opencode.nix).
  sops-nix.nixosModules.sops
  ../../common/sops.nix

  ../../users/cjdell

  # The bare desktop: SDDM + Plasma 6 + NetworkManager + PipeWire + Firefox,
  # plus the GB/uk keyboard the fleet uses. Everything heavy is left out on
  # purpose — this box mostly runs folded flat as a heater.
  {
    networking.networkmanager.enable = true;

    services.displayManager.sddm.enable = true;
    services.desktopManager.plasma6.enable = true;

    services.xserver.xkb = {
      layout = "gb";
      variant = "";
    };

    security.rtkit.enable = true;
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
    };

    programs.firefox.enable = true;
  }
]
