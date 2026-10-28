# asus-i7-6700-nixos — ASUS Z170 PRO GAMING desktop (i7-6700 Skylake
# 4c/8t, 16 GiB, GTX 1060 6GB + GTX 970, console on the HD 530 iGPU),
# 192.168.49.65. Rebuilt 2026-10-28 from spare parts and renamed from
# hp-z240-xeon-1240v6-nixos (the old HP Z240 SFF machine — every hardware
# workaround it needed (dead PCH xHCI, 240 W SFF PSU caps, WOL quirks) is
# gone with it). Kept a BARE-MINIMUM build: just enough for a working
# Plasma desktop, plus the folding@home space heater in ./folding-heater.nix.
# Deliberately NOT imported here (all available if wanted again):
#   common/desktop.nix  — the full workstation suite (chrome, zed, kate,
#                         furmark, moonlight, remmina, libvirtd/virt-manager,
#                         bluetooth, appimage binfmt, ddcutil, spice)
#   common/sunshine.nix + sunshine-nvidia.nix, common/nfs.nix,
#   common/podman.nix + hardware.nvidia-container-toolkit
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
  # purpose — this box mostly runs folded flat as a heater. The console is
  # the i7's HD Graphics 530 (i915); the two NVIDIA cards (see
  # ./hardware-configuration.nix) are compute-only here.
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
