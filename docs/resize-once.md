# One-time root resize of zen3-nixos (2026-08-14) — post-mortem

**Status: COMPLETED successfully.** `/dev/nvme1n1p3` (the WD_BLACK SN770 1TB root
partition) grew from **181G to 250G**, `/home` (p5) shrank from **750G to ~681G**,
to make room for a larger Nix store. The code that did this lives in
`hosts/zen3-nixos/resize-once.nix` (import commented out in `default.nix`).

## Why this was hard

The root partition is the **last partition physically on the disk**:

```
[p1 BIOS 1M][p2 ESP 548M][p5 /home 750G][p3 / 181G]  <- end of disk
```

A partition can only be grown by extending its *end*. p3's end is already at the
end of the disk, so the only space available (after shrinking /home) is on p3's
*start* side. Growing into it means **moving the root filesystem 69G leftward** —
relocating ~96G of data — which can never happen while `/` is mounted.

→ The operation had to run as a **one-shot systemd service inside the initrd**,
before *any* partition of the disk is mounted (stage 1). It cannot run in stage 2
(even "before /home mounts") because `/` is already mounted there.

## How the final solution works

- **Flag:** `/resize-once.flag` at the *root of the root filesystem*. The initrd
  reads it with `debugfs` (direct ext4 access — no mounting needed).
- **Device resolution:** everything is resolved by **fs UUID** via
  `/dev/disk/by-uuid/...`, never by `/dev/nvmeXn1Y` paths (see gotchas).
- **Phase 0 (safe):** `e2fsck -f` + `resize2fs` shrink `/home` to 681G, then the
  partition is shrunk with `sgdisk` (PARTUUID preserved). Failures here leave the
  system bootable (log + continue booting).
- **Phase 1 (point of no return):** `e2fsck -f` + `resize2fs -M` minimise root,
  `dd` the image leftward (forward order is safe: dest < source), recreate p3 at
  the new start (PARTUUID preserved), `resize2fs` grow to 250G, final `e2fsck`.
  Failures here power the machine off rather than boot a half-moved root.
- **Log:** written back into the root fs as `/resize-once.log` via `debugfs -w`.

Arming sequence (still valid if ever reused):

```sh
sudo nixos-rebuild switch --impure --flake . --max-jobs 1
sudo nixos-confirm                 # autoRollback host — mandatory!
sudo touch /resize-once.flag
sudo reboot
cat /resize-once.log && lsblk && df -h /
```

## The geometry (verified before arming by `scripts/check-resize-once.sh`)

| | start sector | end sector | size |
| --- | --- | --- | --- |
| p2 ESP | 4096 | 1126399 | 548M |
| p5 /home (before) | 1126400 | 1573990399 | 750G |
| p3 / (before) | 1573990400 | 1953525134 | 181G |
| p5 /home (after) | 1126400 | 1429237759 | ~681G |
| p3 / (after) | 1429237760 | 1953525134 | 250G |

Resize2fs target for /home: `178513920` 4K blocks. dd offsets: skip `196748800`,
seek `178654720` (4K blocks). fs UUIDs preserved throughout (no reformatting), so
NixOS kept mounting by UUID with zero config changes.

## What went wrong on the way (three failed attempts)

1. **Attempt 1 — ESP flag + hardcoded `/dev/nvme1n1*` paths.** The initrd failed
   with `mount: /esp: unknown filesystem type 'vfat'` — the initrd doesn't bundle
   the vfat kernel module (it's not in `boot.initrd.availableKernelModules`).
2. **Attempt 2 — added `vfat` to `boot.initrd.kernelModules` + by-UUID paths.**
   The ESP mount then failed with `bad superblock on /dev/nvme0n1p2` — mounting
   vfat from the initrd proved unreliable on this host even with the module.
   Lesson: **don't mount the ESP from the initrd; use the root fs + `debugfs`**.
3. **Attempt 3 — rebuild failed with `No space left on device`** copying the
   initrd to the ESP: **42 profile generations** were keeping ~550MB of kernels +
   initrds on the 548MB ESP. Fixed with `nix-env --profile /nix/var/nix/profiles/system
   --delete-generations +2` + manually deleting unreferenced files
   (`/boot/EFI/nixos/*`). The NixOS bootloader installer prunes unreferenced
   files, but *after* copying new ones — so the ESP needs room for the new
   initrd up front.

## Lessons learned

- **NVMe device names swap between boots on this host.** The WD Black has been
  both `nvme0n1` and `nvme1n1` (two NVMe drives present). Always resolve by fs
  UUID, never by `/dev/nvmeXn1Y` — and *don't* hardcode device unit names in
  systemd (`after = dev-nvme1n1p3.device`).
- **Mounting vfat from the initrd is fragile.** Use `debugfs` on the root fs for
  the flag/log instead — the root fs is the one filesystem guaranteed to work.
- **`debugfs -w "write"` does not overwrite an existing file.** The log only kept
  its first checkpoint for this reason. To capture later checkpoints, `rm` the
  destination first or use unique filenames. (Silently swallowed by `|| true`.)
- **autoRollback:** after *every* `nixos-rebuild` on this host, run
  `sudo nixos-confirm` — the timer reboots the machine into `system-good` within
  5 minutes otherwise.
- **The ESP fills up from accumulated generations.** Prune the system profile
  (`nix-env --delete-generations`) when boot entries accumulate.
- **`set -e` + `|| abort` patterns:** guard every destructive step; abort (boot
  normally) before the point of no return, power off after it.
- **Timeout:** a oneshot initrd service doing fsck + ~96G dd needs
  `TimeoutStartSec = "infinity"` (the 90s default would kill it mid-copy).

## Reuse

To resize again (e.g. grow `/` more, or give space back to `/home`):
1. Uncomment `./resize-once.nix` in `hosts/zen3-nixos/default.nix`.
2. Update the geometry constants in the script + `scripts/check-resize-once.sh`.
3. Rebuild, confirm, arm the flag, reboot (see above).
