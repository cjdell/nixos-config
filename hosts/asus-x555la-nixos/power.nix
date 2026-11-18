# Never let this laptop go to sleep. It has no working battery and no working
# RTC cell, so "suspend" is not a power-saving feature here — it is an outage
# with no wake path: Wake-on-WLAN is off, the gigabit port has no cable, and
# there is no serial or remote-management handle. Someone has to press a
# button. So sleep is removed from the system rather than discouraged.
#
# Why this is here, and what it is NOT (2026-11-18, corrected same day).
#
# What it IS: a guard for a real hazard. users/cjdell/nix.nix enables
# autoLogin, so a graphical boot always starts a GNOME session, and upower
# reports the dead pack as `energy-full: 0 Wh` / `percentage: 0%` — the exact
# reading GNOME's critical-battery action and `sleep-inactive-*-type` act on.
# For a box with no WoL, no cable, no serial and no BMC, one such action is an
# outage that needs someone to walk over and press a button.
#
# What it is NOT is the explanation for the adoption-day failure — I asserted
# that here first and the evidence says otherwise. Boot -3 did not end in a
# suspend: its last entries are an ssh session from zen3 at 02:56:33 and then
# *nothing* — no `suspend: Entering`, no OOM, no MCE, no shutdown sequence. A
# log-less instant stop is not what logind/gsd suspend looks like. The new
# generation then stopped ~4 s into boot, twice (boots -2 and -1), also with
# nothing in the journal. Two silent stops, and pstore is unavailable on this
# box (`Platform Persistent Storage Archival skipped`), so a kernel panic here
# would leave no trace either. Candidate causes still open: power delivery
# (SMART on the SSD reads healthy — 0 reallocated/pending/uncorrectable/CRC —
# but Power_Cycle_Count 756 in 618 Power_On_Hours with Power-Off_Retract_Count
# 44 says this machine has been cutting power abruptly all its life), thermal
# trip (idle reads 34-37 °C; the soak to date has been too short to judge), or
# the new kernel/systemd pair (6.18.57 + systemd 262 vs the working 6.18.52).
# Diagnose the boot failure separately — ./power.nix does not fix it.
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
