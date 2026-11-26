#!/bin/sh
# Remote-rebuild dead-man switch.
#
# Use on a host you can only reach over the network: arm it just before a
# `nixos-rebuild switch`, and it reverts to the generation marked in
# /nix/var/nix/profiles/system-good (and reboots) unless you confirm.
#
#   sudo install -m755 scripts/remote-rebuild-guard.sh /root/remote-rebuild-guard.sh
#   sudo rm -f /run/rebuild-ok
#   sudo systemd-run --on-active=25min --unit=remote-rebuild-guard \
#        /root/remote-rebuild-guard.sh
#   # ... rebuild, verify ...
#   sudo touch /run/rebuild-ok && sudo systemctl stop remote-rebuild-guard.timer
#
# Why it exists next to system.autoRollback (nixos-utils): that timer lives in
# the NEW generation, so a generation whose systemd units/config are broken
# cannot run it. A transient unit from the OLD generation survives the switch
# (switch-to-configuration does not restart systemd), so this covers that case.
#
# It rolls back the same way `nixos-rebuild switch --rollback` would, and only
# acts when /nix/var/nix/profiles/system-good exists and differs.
set -eu
exec >>/var/log/remote-rebuild-guard.log 2>&1
echo "=== $(date -Is) guard fired ==="

if [ -e /run/rebuild-ok ]; then
  echo "confirmed via /run/rebuild-ok; nothing to do"
  exit 0
fi

if [ ! -L /nix/var/nix/profiles/system-good ]; then
  echo "no system-good generation; exiting without changing anything"
  exit 0
fi

good="$(readlink -f /nix/var/nix/profiles/system-good)"
current="$(readlink -f /run/current-system)"
if [ "$good" = "$current" ]; then
  echo "current generation is already system-good; nothing to do"
  exit 0
fi

echo "NOT confirmed -> rolling back to $good"

# Point the system profile back at the known-good generation ...
nix-env -p /nix/var/nix/profiles/system --set "$good"
# ... make it the bootloader default ...
"$good/bin/switch-to-configuration" boot
sync
echo "rebooting"
# ... and reboot (sysrq as a fallback if systemd is wedged).
systemctl reboot || echo b > /proc/sysrq-trigger
