# Remote safety net for colin.
#
# colin is a satellite host: it sits on 192.168.178.0/24 behind TalkTalk and is
# only reachable over the internet (tailnet 100.64.0.13 / public nginx). A bad
# activation that breaks networking, sshd or the tailscale/wireguard client
# would strand it, so it runs the fleet's rollback module.
#
# Semantics (nixos-utils modules/rollback.nix): a timer fires `timeout` after
# every activation. If /run/current-system differs from
# /nix/var/nix/profiles/system-good it rolls back to system-good, re-installs
# the bootloader and reboots. It is disarmed by `sudo nixos-confirm`.
#
# => after EVERY `nixos-rebuild switch` on this host, verify it is still
#    reachable, then run `sudo nixos-confirm` within the timeout.
# system-good was bootstrapped to the 25.11 generation colin was running
# before this module existed (y3fvglvz...), so even the first switch was
# covered; it now tracks the unified 26.11 generation after each confirm.
{ ... }:

{
  system.autoRollback = {
    enable = true;
    # Fleet default is 5 min; keep it short because a stranded host is worse
    # than an unintended rollback (a rollback is only ever to a verified gen).
    timeout = "5 min";
  };
}
