# hp-z240-xeon-1240v6-nixos — HP Z240 SFF (Xeon E3-1240 v6 Kaby Lake
# 4c/8t, 8 GiB, GTX 970 — which is also the only display output, this Xeon
# has no iGPU), Micron 2300 NVMe, 192.168.49.59 (was dynamic .156).
# Adopted 2026-11-14 as a fresh install onto a blank NVMe.
#
# NOT the old .65 box: that Z240 (dead PCH xHCI, 240 W PSU brown-out
# derates) was rebuilt into asus-i7-6700-nixos on 2026-10-28; this is a
# second Z240 SFF of the same model — same CPU and a GTX 970 too, hence the
# resurrected host name. Its xHCI WORKS (verified on the install stick:
# keyboard receiver + USB stick enumerated on xhci_hcd, no -110), so no
# `xhci_hcd.quirks` kernel param here.
#
# Kept a BARE-MINIMUM build like its siblings: just enough for a working
# Plasma console, plus the folding@home space heater in ./folding-heater.nix.
# Deliberately NOT imported here (all available if wanted again):
#   common/desktop.nix  — the full workstation suite
#   common/sunshine.nix + sunshine-nvidia.nix, common/nfs.nix,
#   common/podman.nix + hardware.nvidia-container-toolkit
#
# mkHost (flake.nix) supplies common/system.nix (incl. build-client → zen3),
# users/cjdell, home-manager and commonModules; users/cjdell/nix.nix brings
# the account, SSH keys, auto-login, and (via home.nix) powerdevil
# auto-suspend=off + no baloo.
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
  # the GTX 970 (see ./hardware-configuration.nix).
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
