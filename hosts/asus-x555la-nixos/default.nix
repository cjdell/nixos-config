# asus-x555la-nixos — ASUS X555LA laptop (i3-4030U Haswell, 2c/4t @1.9 GHz,
# 11 GiB RAM, Intel HD 4400, 120 GB KingDian S280), 192.168.49.70 (was
# dynamic .152). Adopted 2026-11-18 from a hand-written /etc/nixos install of
# 2026-09-20 that had never been in the flake (hostname was `asus-haswell`;
# no machines/* config existed for it, and its ~/nixos-config copy was not a
# git repo). It is now a normal fleet member on the unified pin; **it has no
# role yet** — see the measured facts at the bottom before giving it one.
#
# mkHost (flake.nix) supplies common/system.nix (→ common/build-client.nix,
# wheelNeedsPassword=false, mitigations=off, the fleet CLI set), users/cjdell,
# home-manager + homeManagerPrefs and commonModules, and sets
# networking.hostName from the directory name — so the hostname changes from
# `asus-haswell` to `asus-x555la-nixos` on the first switch.
#
# Deliberate choices, all reversable in one line:
#
#   - ./desktop.nix keeps the *minimal* GNOME the box was installed with,
#     rather than importing common/gnome.nix: that module is the full
#     alderlake-thinkpad workstation (vscode, zed, bottles, moonlight-qt,
#     ddcutil, geekbench, ...) and this root is 107 GiB on a no-name SSD.
#     There was a live GNOME session on tty2 at adoption, so the desktop is
#     not being re-implemented here, just declared.
#   - NO common/sops.nix: nothing here needs a secret, and
#     users/cjdell/opencode.nix is written to degrade when
#     /run/secrets/brave_api_key is absent (like rocketlakelatitude).
#     Installing the shared age key is a role decision, not an adoption step.
#   - NetworkManager stays (./desktop.nix). The only working link is Wi-Fi —
#     the r8169 gigabit port is carrier=0, no cable — and the PSK lives in
#     /etc/NetworkManager/system-connections, which Nix does not manage: a
#     systemd-networkd host here has to be re-joined at the console.
#   - ./hardware-configuration.nix mounts by UUID, not the fleet's by-label
#     BOOT/ROOT: this install labels its partitions ESP/nixos/swap, and
#     renaming a live ESP buys nothing for the risk of an unbootable box.
#   - No system.stateVersion here, so it inherits common/system.nix's "24.11"
#     exactly like every other host (hp-z240-xeon-1240v6-nixos, installed on
#     26.11, does the same). Do not "fix" that by setting it in this file: it
#     is a hard eval failure, not an override — the host is imported after
#     common/system.nix, so a second plain definition of the same option makes
#     `nix eval` die with "The option `system.stateVersion' has conflicting
#     definition values" (observed 2026-11-18). Only the *effective* value
#     changes if one side is ever wrapped in mkDefault/mkForce.
#   - system.autoRollback is NOT enabled: a forgotten `nixos-confirm` would
#     reboot a box that currently holds nothing. Worth adding once it has
#     state worth guarding (the module is in commonModules already).
#
# Measured 2026-11-18, the facts that constrain any future job:
#   - Battery dead: upower energy-full 0 Wh, `pending-charge`, percentage 0%.
#     → it is a mains device with NO UPS. The RTC coin cell is dead too
#     (uptime reported 6530 days after the clock jumped), so **every mains
#     outage resets the clock** — bad for snapshot naming, cert validity and
#     any timestamped sync. Both packs are cheap; say so before trusting it
#     with anything time-ordered.
#   - Wi-Fi is 1x1 2.4 GHz ath9k: RTT avg 15.6 ms, max 137 ms, mdev 30.9 ms,
#     against 0.62 / 0.90 / 0.22 ms for a wired peer on the same LAN
#     (N100-NAS). Two 32 MB incompressible copies did not finish inside a
#     90 s window. Fine for probes and small state, not for store deltas.
#   - The webcam ("USB2.0 VGA UVC WebCam") is 640x480 — not a camera.
#   - Usable hardware: 15.6" panel + keyboard + speakers (a console/alarm
#     surface), an SD/MS card reader (rtsx_usb), DVD±RW, HDMI *out*, and
#     VT-x. No AVX-512, no useful Vulkan/Compute on HD 4400, no HEVC.
#   - smartmontools / ethtool / pciutils / dmidecode / tio were ABSENT on the
#     old install (which is why the first survey could not read SMART); they
#     arrive with sharedPackages, kept on for exactly that reason.
#
# Takes the flake inputs like every hosts/<name>/default.nix (mkHost does
# `import ./hosts/<name> inputs`); none of them are needed here.
{ ... }:

[
  ./desktop.nix
  ./hardware-configuration.nix
]
