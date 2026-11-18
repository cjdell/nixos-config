# Never let this laptop go to sleep. It has no working battery and no working
# RTC cell, so "suspend" is not a power-saving feature here — it is an outage
# with no wake path: Wake-on-WLAN is off, the gigabit port has no cable, and
# there is no serial or remote-management handle. Someone has to press a
# button. So sleep is removed from the system rather than discouraged.
#
# Why this is load-bearing and not paranoia (2026-11-18): during the adoption
# switch the box stopped answering on L2 mid-activation — `ip neigh` FAILED, no
# dnsmasq renewal, no ssh — 6 minutes in, and stayed down. Prime suspect: the
# fresh GNOME session (users/cjdell/nix.nix enables autoLogin, so activating
# the new system starts a new gsd-power) reading the dead pack — upower
# reports `energy-full: 0 Wh`, `percentage: 0%`, `state: pending-charge` — and
# GNOME's *critical battery* action firing on exactly that reading, on top of
# `sleep-inactive-*-type` defaulting to suspend. The old session had lived
# with the same reading for weeks; a clean state machine acted on it. Not
# provable from here while the box is asleep — which is itself the lesson:
# there is no way to find out remotely.
#
# Three layers, because the request arrives from three places:
#   1. `systemd.suppressedSystemUnits` — gsd and logind both end up at
#      sleep/suspend/hibernate targets; suppressed units are dropped from the
#      generated unit set, so the request has nothing to start. This is the
#      layer that actually stops it.
#   2. `systemd.sleep.settings.Sleep.*` — makes `systemctl suspend` fail even
#      for a caller that goes straight at systemd-suspend.service.
#   3. `services.logind.settings.Login` lid/idle keys — closing the lid is
#      inert, and a stray power-button press locks instead of powering off.
#
# ⚠️ Option names here are the *post-restructure* ones, and that matters:
# common/nosleep.nix — imported by kabylakeitx-nixos and others — has its whole
# body commented out, and the body it would restore (`systemd.sleep.extraConfig
# = ''AllowSuspend=no …''`) is a REMOVED option on this pin
# (nixos/modules/system/boot/systemd.nix:960 says "Use
# systemd.sleep.settings.Sleep instead"). Uncommenting that file would now fail
# the build. Masking moved too: neither `systemd.maskedUnits` nor
# `systemd.maskedTargets` exists on this pin (both are eval errors);
# `systemd.suppressedSystemUnits` does (systemd.nix:532). Verified by
# evaluation, not memory.
#
# Deliberately NOT done: overriding GNOME's
# org.gnome.settings-daemon.plugins.power critical-battery-action in Nix.
# Layer 1 already stops the suspend, and a gsettings override would be a second
# schema-version-sensitive mechanism for the same job.
{ ... }:

{
  systemd.sleep.settings.Sleep = {
    allowSuspend = false;
    allowHibernation = false;
    allowHybridSleep = false;
    allowSuspendThenHibernate = false;
  };

  systemd.suppressedSystemUnits = [
    "sleep.target"
    "suspend.target"
    "hibernate.target"
    "hybrid-sleep.target"
    "suspend-then-hibernate.target"
    "systemd-suspend.service"
    "systemd-hibernate.service"
    "systemd-hybrid-sleep.service"
    "systemd-suspend-then-hibernate.service"
  ];

  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
    IdleAction = "ignore";
    # The power button is the only way to turn this box off and it has no
    # battery to drain, so a stray press must not be an instant power cut.
    HandlePowerKey = "lock";
  };
}
