# Never let this laptop go to sleep, and never let UPower act on its dead
# battery. It has no working battery and no working RTC cell, so "suspend" is
# not a power-saving feature here — it is an outage with no wake path:
# Wake-on-WLAN is off on ath9k, the gigabit port has no cable, and there is no
# serial or remote-management handle. Someone has to press a button. So sleep
# is removed from the system rather than discouraged.
#
# Three layers, because the request can arrive from three places:
#   1. `services.upower.criticalPowerAction = "Ignore"` — UPower sits at its
#      distribution default `CriticalPowerAction=HybridSleep` with
#      `PercentageAction=2` / `UsePercentageForPolicy=true` while this machine
#      reports a permanently `0%`, `0 Wh`, `pending-charge` pack forever. That
#      is a loaded gun, and UPower is the actor that can fire it *earliest* —
#      as soon as upowerd starts, before any desktop. `Ignore` is the "risky"
#      value (the pack will never recover, so doing nothing is exactly what we
#      want), hence allowRiskyCriticalPowerAction.
#   2. `systemd.suppressedSystemUnits` — gsd-power and logind both end up at
#      sleep/suspend/hibernate targets; suppressed units are dropped from the
#      generated unit set, so the request has nothing to start.
#   3. `systemd.sleep.settings.Sleep.*` + `services.logind.settings.Login` —
#      `systemctl suspend` fails outright, closing the lid is inert, and a
#      stray power-button press locks instead of powering off (that button is
#      this box's only shutdown path).
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
# Layers 1-2 already stop the suspend, and a gsettings override would be a
# second, schema-version-sensitive mechanism for the same job.
#
# ── And what this file is NOT: the cause of the adoption-day cut-outs ────────
# Those were **power delivery — the AC supply was running under-voltage**. The
# fix was raising the PSU output, and the machine has been stable since
# (2026-11-18, same day). Nothing in this file, or in NixOS, was involved.
#
# The reason to keep this paragraph is that I got the diagnosis wrong TWICE in
# one day, and the second error is the instructive one:
#   1. First read (correct): boot -3 ends with an ssh session from zen3 at
#      02:56:33 and then nothing — no `Suspending`, no OOM, no MCE, no
#      shutdown sequence. logind and gsd-power both LOG a suspend, so the
#      silence is genuine evidence *against* a suspend.
#   2. Then came "it went to sleep" — one observation of a black screen and a
#      dead network, which is also exactly what an under-volted rail looks
#      like — and I flipped, called sleep decisive, and queued a kernel
#      bisect. Three hard signals argued against it throughout:
#      `Power-Off_Retract_Count 44` on a 618 h drive; both generations failing
#      identically at ~4 s (no config explains that); and `asus_wmi: failed to
#      register LPS0 sleep handler in asus-wmi`, i.e. this box can barely S3 in
#      the first place. pstore is also unavailable here (`Platform Persistent
#      Storage Archival skipped`), so a silent stop is *expected* from hardware
#      and proves nothing about software in either direction.
#   3. The generation that "would not boot" booted fine as soon as the rail was
#      right. It is the running system.
#   An anecdote about a symptom should not outrank a SMART counter that only
#   moves on unclean power loss. And note: raising the supply voltage is a
#   mitigation, not a diagnosis of *why* it was low. A worn barrel jack, a
#   tired brick or dead pack-detection circuitry all do this; the proper fix is
#   a correct 19 V / 2.37 A (45 W) adapter. Until that is settled, do not trust
#   this box with state that must survive a write.
{ ... }:

{
  services.upower.criticalPowerAction = "Ignore";
  services.upower.allowRiskyCriticalPowerAction = true;

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
