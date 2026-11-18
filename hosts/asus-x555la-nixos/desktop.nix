# The console this box was installed with on 2026-09-20, declared rather than
# re-implemented: GDM + GNOME + PipeWire + Chrome, on Wi-Fi under
# NetworkManager. Deliberately NOT common/gnome.nix (that is the full
# alderlake-thinkpad workstation set — vscode, zed, bottles, moonlight-qt,
# ddcutil + the out-of-tree ddcci module — several GB on a 107 GiB root).
#
# The xkb layout stays `us` because that is what is configured today, even
# though the fleet convention is `gb` (common/gnome.nix, hp-z240) and
# common/system.nix already sets the *console* keymap to `uk`. Changing the
# layout of a keyboard someone is typing on is not an adoption change:
# flip it here if the panel turns out to be a UK one.
#
# services.xserver.enable is not set: GDM brings up what it needs, and this is
# the form common/gnome.nix uses on the pin.
{ pkgs, ... }:

{
  networking.networkmanager.enable = true;

  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;

  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  environment.systemPackages = with pkgs; [
    google-chrome
  ];
}
