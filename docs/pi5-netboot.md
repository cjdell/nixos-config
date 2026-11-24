> Archived from AGENTS.md (2026-11-24). The short version lives in AGENTS.md; this file holds the full backstory.

## Pi 5 netboot (aarch64) — currently switched OFF

A headless Raspberry Pi 5 (MAC `98:fe:54:18:17:e9`, no SD card) network-boots
NixOS from zen3. Full journey + gotchas: `pi5-blog.md`; status: `pi5-progress.md`.

⚠️ **None of this is deployed at the moment** (verified 2026-10-18): `dc54f4a`
"Temporarily remove un-needed things" (2026-09-28) commented `./netboot.nix`,
`./pi5-netboot.nix` and `./pi5-deploy.nix` out of
`hosts/zen3-nixos/default.nix`. The running system therefore declares no tftpd
unit and no `/etc/tftp/e9cf02dc` / `/exports/nix-store` bind mounts — what is in
`/etc/tftp` is a plain August directory, nothing is mounted over it, and the Pi
does not answer a ping at `.92`. Everything below describes the setup as it
should come back (uncomment the three imports, `nixos-rebuild switch`), not the
current system. It also means `gc-rust-node` is a locked-but-unused input while
these stay commented out.

- **The Pi's boot files are part of this system now** (`hosts/zen3-nixos/pi5-netboot.nix`):
  the `gc-rust-node` flake input (`git+file://` — commit in that repo first,
  then `nix flake update gc-rust-node`) builds the complete eeprom boot
  dir — `config.txt`, `dtb`, `armstub8-2712.bin` (TF-A rpi5), `Image`,
  `initrd`, `cmdline.txt` (derived from `boot.kernelParams`) **plus the Pi's
  Nix store snapshot** (`nixStore/`, the full toplevel closure +
  `nix-path-registration`) — via its parameterized `lib.mkPi5Netboot`, fed
  with this host's deployment values (`services.pi5Netboot.*` in
  `hosts/zen3-nixos/pi5-deploy.nix` — the gc-rust-node repo itself contains
  no IPs or join codes). This
  host bind-mounts the bundle at `/etc/tftp/e9cf02dc` (eeprom boot dir, TFTP)
  and its `nixStore/nix-store` at `/exports/nix-store` (the Pi's NFS store).
  **The store served to the Pi is the bundle's snapshot — NOT this host's live
  `/nix/store`.** **Deploying a Pi update == `nixos-rebuild switch`
  on this host** (+ `sudo nixos-confirm`, autoRollback is on) + a Pi
  power-cycle. No runtime copies into /etc/tftp.
- **Build = build machine, not manual copies:** the MacBookAir
  (`cjdell@192.168.49.69` — static lease on MAC `00:0e:c6:8e:b3:ff`, its wired
  `enu1`; NixOS config in `/home/cjdell/nixos-config/` there, rebuild with `just
  switch` in that dir — `--impure` required) is a Nix build
  machine for zen3: `nix.buildMachines` in `hosts/zen3-nixos/default.nix` (root
  key `/root/.ssh/id_ed25519` authorized on the MacBook, `cjdell` in its
  `nix.trustedUsers`, `supportedFeatures = [ "big-parallel" ]` — without it the
  linux-rpi kernel drv is kept local and fails with "platform mismatch").
  The Pi's NixOS config lives in the gc-rust-node repo
  (`~/Projects/gc-business/gc-rust-node`, pi5/ + the `nixosSystem` in its
  `flake.nix`); it builds with its own nixpkgs pin (does NOT follow this
  flake's nixpkgs — the Pi keeps its tested toolchain). aarch64 drvs are
  dispatched to the MacBook and land in zen3's own store as build inputs; the
  Pi boots the bundle's store snapshot (see above), so it is decoupled from
  zen3's live store and GC.
  **No rsync / manual store copy.**
- **Deploy:** `./scripts/update-pi5-node.sh` (enroll fresh join code into
  `hosts/zen3-nixos/pi5-deploy.nix` → re-lock
  the gc-rust-node input → `nixos-rebuild switch` → `nixos-confirm` →
  power-cycle via the HA relay — `scripts/pi5-powercycle.sh` → verify
  gc-node/sshd/toplevel/cmdline). The `/exports` NFS root is exported with
  `crossmnt` PLUS an explicit `nohide` `/exports/nix-store` sub-export (in
  `hosts/zen3-nixos/netboot.nix`): without the sub-export the crossed entry
  shares the parent's fsid=0, and a client mounting `:/nix-store` gets an
  ambiguous file handle (`fileid changed` / `Stale file handle` in the
  initrd — stage-2 never comes up). The sub-export pins the bind mount, so a
  switch's restart of `exports-nix\x2dstore.mount` can fail (exit 4) — the
  script tolerates that, detects the stale mount, and fixes it (lazy-umount,
  remount, full `exportfs -ua; exportfs -a`). The Pi has a static lease at **192.168.49.92**
  (router dnsmasq `dhcp-host=set:pi5,98:fe:54:18:17:e9,192.168.49.92,pi5,1h`
  + `dhcp-boot=tag:pi5,pi5,192.168.49.50` in
  hosts/grafton-router/networking/dns.nix — note the dhcp-host field order:
  `set:<tag>` BEFORE the IP, hostname AFTER it). It
  regenerates its SSH host keys every boot (tmpfs root) — expect host-key
  warnings, or pin them in the pi5 flake (`services.openssh` host keys) at
  `~/Projects/gc-business/gc-rust-node/pi5/configuration.nix`.
- **TFTP server = the NixOS `tftpd` unit** (`hosts/zen3-nixos/netboot.nix`),
  `in.tftpd -l -s -a 192.168.49.50:69 /etc/tftp`. The `-s` is mandatory:
  without it the directory arg is only an allow-list prefix and relative
  requests fail with "Only absolute filenames allowed" (the eeprom + iPXE send
  relative names). An earlier ad-hoc python `pi5-tftpd` unit was deleted by a
  NixOS reactivation (NixOS removes unit files it doesn't own) — don't run
  ad-hoc TFTP servers on this host; use the unit.
- Boot flow: eeprom TFTP-fetches `e9cf02dc/{config.txt,dtb,cmdline.txt,Image,
  initrd,armstub8-2712.bin}` → kernel + initrd (networkd DHCP, NFSv4 store
  mount from the bundle's snapshot, systemd) → `pi5` over SSH.
  `armstub8-2712.bin` is the TF-A rpi5 build
  (bl31.bin) — built from source in the gc-rust-node flake (`pi5Armstub`,
  v2.15.0) — see pi5-blog.md.

