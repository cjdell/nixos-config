# Plasma 6 session hardening, imported by common/desktop.nix and
# common/desktop-light.nix (so every Plasma host gets it).
#
# The problem: nixpkgs' plasma6 module deletes the KDE service-type cache at
# *boot*, from a place the graphical session is not ordered against:
#
#   pkgs/top-level/.../nixos/modules/services/desktop-managers/plasma6.nix:21
#     activationScript = ''rm -fv "''${XDG_CACHE_HOME:-$HOME/.cache}/ksycoca"*'';
#   :406  system.userActivationScripts.rebuildSycoca = activationScript;
#
# `system.userActivationScripts` runs from `nixos-activation-start`, i.e. during
# boot activation, while SDDM is already bringing up the session. The first KDE
# apps then race to rebuild the cache. Measured on macbook-pro-2009-nixos,
# 2026-11-01, one boot (journal + ~/.cache mtimes):
#
#   13:18:19  nixos-activation-start[1161]: removed '.../.cache/ksycoca6_en-GB_...'  (x3)
#   13:18:24  ksycoca6_en-GB_1M_kSb_... written
#   13:18:26  plasma-plasmashell.service: Started
#   13:18:28  ksycoca6_en-GB_P_pskF... written
#   13:18:31  ksycoca6_en-GB_7vyy3L... written
#
# i.e. plasmashell built its applet/app model while the cache was being written
# under it, and one applet (the Kickoff launcher) came up present-but-dead: the
# icon was on the panel, clicking it did nothing, D-Bus
# `org.kde.PlasmaShell.activateLauncherMenu` changed no pixels, and plasmashell
# logged nothing at all. `systemctl --user restart plasma-plasmashell` with a
# complete cache on disk fixed it, which is how you can tell it is a load-time
# race and not a missing package — the applet plugin
# (/run/current-system/sw/lib/qt6/plugins/plasma/applets/org.kde.plasma.kickoff.so,
# from plasma-desktop; Plasma 6.8 builds the default applets into plugin
# libraries, so they are *not* under `share/plasma/plasmoids`) and every
# .desktop file were there the whole time.
#
# The fix: rebuild the cache synchronously before the shell starts, so its
# ExecStart reads a finished file. A user unit cannot order itself after the
# system-level activation unit that does the deleting, so re-creating the cache
# here is the only lever we have. Costs ~1 s at login.
{
  config,
  lib,
  pkgs,
  ...
}:

lib.mkIf config.services.desktopManager.plasma6.enable {
  systemd.user.services.plasma-plasmashell = {
    # Also cover the session-level variant of the same deletion (plasma6.nix:407
    # `nixos-rebuild-sycoca.service`, WantedBy=graphical-session-pre.target).
    # Ordering against a unit that is not running is a no-op, so this is safe.
    after = [ "nixos-rebuild-sycoca.service" ];

    # `--noincremental` = re-read everything rather than patch the existing file.
    # Runs as the session user (no `+`), and kbuildsycoca6 locks the cache, so a
    # concurrent krunner/ksmserver rebuild serialises instead of interleaving.
    serviceConfig.ExecStartPre = "${lib.getExe' pkgs.kdePackages.kservice "kbuildsycoca6"} --noincremental";
  };
}
