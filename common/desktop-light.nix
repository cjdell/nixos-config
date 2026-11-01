# A lean Plasma desktop: the same login/session stack as `common/desktop.nix`
# (NetworkManager + PipeWire + SDDM + Plasma 6, UK keymap), with everything the
# machine does not need taken out instead of shipped by default.
#
# It exists for `macbook-pro-2009-nixos`, the Pinnacle PCTV 320cx capture
# station (see `machines/macbook-pro-2009/default.nix` and `docs/pctv-320cx.md`),
# whose job is: boot to Plasma, run `pctv-monitor` (SDL2, from
# `pctv-linux/live-module.nix`), play the resulting .mpg back in VLC, and get
# the files onto the NAS.
#
# What that leaves out compared with `common/desktop.nix`, and what each was
# costing in the *closure* (measured on that box with
# `nix path-info -rsS /run/current-system` before the change, 19.8 GB total):
#
#   obs-studio        92 MB itself, but it owns `cef-binary`: 1.99 GB
#   google-chrome     435 MB
#   firefox           388 MB (+ openvino 142 MB via onnxruntime for translations)
#   zed-editor        358 MB (+ livekit-libwebrtc 218 MB)
#   furmark           38 MB
#   virtualisation.libvirtd + virt-manager   992 MB qemu + 62 MB libvirt
#   podman (host module list)               72 MB cni-plugins + crun + ...
#   imsprog           3 MB + the 90 MB minimal JRE it runs on
#   remmina, moonlight-qt, gnome-disks, appimage-run, ddcutil, notify-desktop,
#   mesa-demos, xhost, hardware.bluetooth (bluez + bluedevil + bluez-qt)
#
# and, inside Plasma itself (all of these are the module's own defaults, so
# they arrive on *every* Plasma host here, not just this one):
#
#   services.orca     700 MB: orca -> speech-dispatcher -> mbrola voices
#   programs.kde-pim  akonadi + the MariaDB server it runs on, ~300 MB
#   services.fwupd    9 MB itself + pulls `discover` (Plasma's updater) in
#   khelpcenter       466 MB, almost all of it qtwebengine for one doc viewer
#   plasma-workspace-wallpapers  255 MB of multi-monitor artwork
#
# Deliberately KEPT: Plasma 6 and VLC (the two things this box is judged on),
# konsole/dolphin/spectacle, Qt5 integration (VLC is a Qt5 app: `pkgs.vlc`
# depends on libsForQt5.qtbase, so that 85 MB is spent either way and the
# integration is what makes it look native), and the `optionalPackages` Plasma
# input-method bits (plasma-keyboard/qtvirtualkeyboard, ~10 MB) because the
# keyboard KCM expects them.
#
# To bring any of it back on a host using this module, set the option again in
# that host's config (everything here is a plain assignment, so nothing needs
# `mkForce`), or just import `common/desktop.nix` there instead.
{
  config,
  lib,
  pkgs,
  ...
}:

{
  # --- the basics ------------------------------------------------------------

  networking.networkmanager.enable = true;

  services.xserver.xkb = {
    layout = "gb";
    variant = "";
  };

  # pctv-monitor records from ALSA `default` — PipeWire's ALSA plugin — and
  # monitors the card's line-in through it, so the sound server is part of the
  # capture path, not desktop decoration. `pctv-linux/live-module.nix` pins the
  # WirePlumber profile (input+output analog stereo) that this needs.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # --- Plasma, trimmed -------------------------------------------------------

  services.displayManager.sddm.enable = true;
  services.desktopManager.plasma6.enable = true;

  environment.plasma6.excludePackages = with pkgs.kdePackages; [
    plasma-workspace-wallpapers # 255 MB, this panel is 1280x800
    khelpcenter # 466 MB, nearly all qtwebengine
    okular
    gwenview
    elisa # vlc plays the music
    ark
    kate # nixpkgs' kate plus its ktexteditor
    ktexteditor
    krdp # RDP client (freerdp); this box is ssh'd into, not remote-desktoped
    aurorae
    union
    plasma-browser-integration # no browser installed
  ];

  # `services.orca`/`programs.kde-pim`/`services.fwupd`/`services.geoclue2` and
  # the two browser-integration hooks are set by the plasma6 module with
  # mkDefault (plain assignment wins) or plainly (mkForce needed).
  services.orca.enable = false; # screen reader -> speech-dispatcher -> mbrola voices
  programs.kde-pim.enable = false; # akonadi + MariaDB
  services.fwupd.enable = false; # nothing updatable on a 2009 MacBook, and it drags in Discover
  services.geoclue2.enable = false; # no GPS
  programs.firefox.nativeMessagingHosts.packages = lib.mkForce [ ];
  programs.chromium.enablePlasmaBrowserIntegration = lib.mkForce false;

  # --- packages --------------------------------------------------------------
  #
  # No browser: `pctv-monitor` and VLC are the whole desktop. One line each to
  # bring one back — `programs.firefox.enable = true;`.
  environment.systemPackages = with pkgs; [
    vlc # playback, and the reason libvlc/phonon was never enough
    mpv # same formats from a terminal (and `mpv av://v4l2:/dev/video0` for the iSight)
    ffmpeg # captures are piped through it; also the transcode/trim tool

    # This host rebuilds itself from ~/nixos-config (see its default.nix and the
    # justfile), and common/system.nix's fleet-wide CLI set is off here.
    git
    just
  ];
}
