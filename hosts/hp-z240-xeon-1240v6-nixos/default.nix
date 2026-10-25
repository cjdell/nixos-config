# hp-z240-xeon-1240v6-nixos — HP Z240 SFF (Xeon E3-1240 v6, GTX 970),
# 192.168.49.65. Converted 2026-10-25 from the legacy inline config in
# flake.nix + machines/hp-z240-xeon-1240v6, deliberately kept a
# BARE-MINIMUM build: just enough for a working Plasma desktop, plus the
# folding@home space heater. Deliberately NOT imported here (all available
# if wanted again):
#   common/desktop.nix  — the full workstation suite (chrome, zed, kate,
#                         furmark, moonlight, remmina, libvirtd/virt-manager,
#                         bluetooth, appimage binfmt, ddcutil, spice)
#   common/sunshine.nix + sunshine-nvidia.nix, common/nfs.nix,
#   common/podman.nix + hardware.nvidia-container-toolkit, and
#   common/folding-at-home.nix (the paused/broken linuxserver FAH container
#   this used — replaced by the native client in ./folding-heater.nix)
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
  # purpose — this box mostly runs folded flat as a heater (the GTX 970 is
  # also its only display output; see ./hardware-configuration.nix).
  {
    # HP Z240 firmware quirk: the BIOS's own xHCI stack (which still drives
    # the keyboard in setup/bootloader) hands the controller over already
    # RUNNING, and the kernel then times out on its CNR handshake —
    # `xhci_hcd 0000:00:14.0: can't setup: -110`, probe fails, no USB
    # devices ever enumerate in Linux (verified on 6.16.7 and 6.18.57; a PCI
    # remove+rescan does not recover it — controller is dead, not busy).
    # quirk bit 16 = XHCI_RESET_TO_DEFAULT: halt + reset the host before
    # start, i.e. undo whatever the firmware left behind. (quirks is read
    # only at module init, so it must be a boot parameter, not a
    # /sys/module write.) If this ever regresses, the other remedy is a
    # COLD power cycle — the controller only misbehaves across warm reboots.
    boot.kernelParams = [ "xhci_hcd.quirks=65536" ];

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
