# colin

ElectroNerds home server at `192.168.178.10` (`electronerds.com`), adopted
into the fleet on 2026-11-26 from its standalone single-host flake. **Its role
is unchanged**: AdGuard, Frigate, Home Assistant, Jellyfin, Immich, filebrowser,
qBittorrent, UniFi, Whoogle, LibreSpeed, Samba, Mosquitto, Postgres, its own
nginx/ACME Route53 edge, the WireGuard client, Tailscale/headscale and the
`create_ap` Wi-Fi AP, all on the `electronerds` ZFS pool.

## Why this host is different

- **Satellite site.** It lives on `192.168.178.0/24` behind TalkTalk, not on the
  fleet's `192.168.49.0/24` LAN, and cannot reach the zen3 builder — not over
  the LAN and not over the tailnet (zen3 has no tailnet node). It must build
  locally; do **not** import `common/build-client.nix`.
- **Own module list.** It does not import `common/system.nix` or `users/cjdell`
  yet (step 2 of the unification).

## Unification status (begun 2026-11-26)

Done:

- **Fleet nixpkgs pin.** `nixosConfigurations.colin` now evaluates on the
  fleet's unified `nixpkgs` (currently 26.11, rev `09063bd`), not the old
  `nixpkgs_25_11`. It moved live: 25.11.20260324.1073dad →
  26.11.20261017.09063bd (`48gk791whd…`), all services verified, Immich DB
  reindexed for the glibc 2.40→2.44 collation change.
- **Fleet sops-nix** (the 25.11 pre-Go-1.26 pin cannot build on unstable).
- **`system.autoRollback`** (see below).
- **`colin-legacy`** output = the exact 25.11 configuration it ran before, kept
  rebuildable while the transitional pins below are in use.

Still pinned to `nixpkgs_25_11` (transitional, both deleted by removing the
override + specialArg):

- **Immich 2.6.1** in `services/immich.nix`. nixos-unstable ships Immich 3.x
  and the module now **always** uses VectorChord; colin's live database is on
  pgvecto.rs. That is a data migration with its own runbook, not part of the
  pin move.
- **pgvecto.rs** (`vectors` 0.3.0) in `services/postgres.nix`, because unstable
  dropped `pgvecto-rs` outright.

So a rebuild from `colin-legacy` is still possible, and the live system still
*looks* like a 2.6.1 Immich host even though everything else is 26.11.

## Remote safety net — read before any rebuild

colin is only reachable over the internet (tailnet `100.64.0.13`, public
`electronerds.com`). A bad activation that breaks sshd/network would strand it,
so `system.autoRollback` is enabled (`./rollback.nix`):

- a timer fires **5 minutes after every activation**;
- if `/run/current-system` differs from `/nix/var/nix/profiles/system-good` it
  rolls back to `system-good`, reinstalls the bootloader and **reboots**.

**After every `nixos-rebuild switch` on colin: verify it is still reachable,
then run `sudo nixos-confirm` within 5 minutes.** Everything else (containers,
nginx, Immich) is checked *after* that.

`system-good` was bootstrapped (before the module existed) to the 25.11
generation colin was running, so even the first switch was covered.

For extra protection the switch itself can be wrapped in an independent
dead-man timer that survives a broken new generation (transient units are not
restarted by activation). It is not in the config; it is a procedure, and the
script lives in this repo:

```sh
sudo install -m755 scripts/remote-rebuild-guard.sh /root/remote-rebuild-guard.sh
sudo rm -f /run/rebuild-ok
sudo systemd-run --on-active=25min --unit=remote-rebuild-guard \
     /root/remote-rebuild-guard.sh
# ... rebuild, verify ...
sudo nixos-confirm
sudo touch /run/rebuild-ok && sudo systemctl stop remote-rebuild-guard.timer
```

`remote-rebuild-guard.sh` rolls back to `system-good` and reboots unless
`/run/rebuild-ok` exists.

**Reboots are the one unprotected step.** `nixos-rebuild switch` does not change
the running kernel; the 26.11 move brought 6.12.77 → 6.18.57, so the next
unattended reboot boots a kernel this host has never run. ZFS is stage-2 (root
is ext4), so a ZFS problem cannot prevent booting; but the first reboot onto
6.18.57 should be done while someone can reach the box. Until then the 25.11
generation remains in the systemd-boot menu.

## Secrets

Secrets live in `hosts/colin/secrets/secrets.yaml` (sops), encrypted to the
fleet age key. `/var/lib/sops-nix/key.txt` must exist on the host; sops renders
`/run/secrets/*` and `/run/secrets/rendered/*` (Route53 env, htpasswd,
`create_ap.conf`) at activation, so nothing secret is in `/nix/store`. The sops
*module* is selected in `flake.nix` alongside the nixpkgs pin.

## Rebuild

```sh
sudo nixos-rebuild switch --flake .        # hostname is colin, so this picks .#colin
sudo nixos-confirm                          # REQUIRED within 5 minutes
```

The 25.11 reference config is `.#colin-legacy` (do not deploy it casually).

## Backups / rollback points

ZFS snapshots were taken immediately before the unification switch:

```
electronerds/ds-postgres@pre-unification-2026-11-26
electronerds/ds-photos@pre-unification-2026-11-26
```

Root (`/`) is ext4, so there is no root snapshot — generation rollback is
`sudo nixos-rebuild switch --rollback` (or `nixos-confirm <gen>`).

The old repo's `mariadb.nix` and `photoprism.nix` were never imported and
referenced constants that do not exist, so they are intentionally not ported
(they remain in `~/nixos-config.pre-fleet-2026-11-26`).

## Remaining unification work

1. Immich 2.6.1 → 3.x + VectorChord migration (needs a DB dump + the documented
   pgvecto.rs → VectorChord steps), then drop both the overrides and the
   `nixpkgs_25_11` / `home-manager_25_11` / `sops-nix_25_11` pins and the
   `colin-legacy` output.
2. First supervised reboot onto kernel 6.18.57.
3. `common/system.nix` + `users/cjdell` — requires an `enable` switch on
   `common/build-client.nix` (or a colin-specific override) because colin must
   not dispatch builds to zen3.
4. `boot.zfs.forceImportRoot = false` (26.11 recommends it; silence the eval
   warning deliberately, not by accident).
