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
- **Immich 3.3.3 + VectorChord** (2026-11-26, this is what removed the last
  25.11 pin — see the migration section below). There are now **no**
  `nixpkgs_25_11` / `home-manager_25_11` / `sops-nix_25_11` inputs left in
  `flake.nix` or `flake.lock`.

## Immich 2.6.1 → 3.x + VectorChord (done 2026-11-26)

Immich 3.0 dropped pgvecto.rs — `DB_VECTOR_EXTENSION` accepts only
`vectorchord` or `pgvector`. Colin's database used the old extension (`vectors`
0.3.0, `vector` columns in `face_search`/`smart_search`), so it was converted
with Immich's documented **automatic** path
(`docs.immich.app/administration/postgres-standalone/#migrating-from-pgvecto-rs`):
pgvecto.rs + pgvector + VectorChord installed together, both preloaded, and the
3.x server did the column/index conversion at startup.

Result (generation `z8azrx4psv…`, 2026-11-26 23:06):

- Immich **3.3.3** (fleet pin); `immich-server` and `machine-learning` healthy.
- `clip_index` (smart_search) and `face_index` (face_search) are now
  `USING vchordrq`; both "Reindexed" messages were logged (~30 s for
  15,795 / 19,095 rows).
- Columns are `public.vector` (pgvector 0.8.7); `vchord` 1.1.1 preloaded only.
- `DROP EXTENSION vectors; DROP SCHEMA vectors;` succeeded (no dependants), and
  the 25.11 override + inputs are gone from the repo.

Backups from before the conversion are still on disk:

```
electronerds/ds-postgres@pre-immich3-2026-11-26
electronerds/ds-photos@pre-immich3-2026-11-26
/electronerds/ds-postgres/dumps/immich-pre-v3-20261126.dump
    pg_dump -Fc, 107 MB, 493 TOC entries (tables + data, incl. the vector tables)
```

They can be pruned once the 3.x install has had some real use (a post-migration
`pg_dump` is the more useful thing to keep).

What the migration used (and what remains in the config):

- `services.postgresql.extensions` = pgvector **0.8.7** + VectorChord **1.1.1**
- `shared_preload_libraries = "vchord.so"` (only; `vectors.so` is gone)
- `services.immich` = **3.3.3** (fleet pin)
- `immich-vectorchord-init.service` is **kept**: a oneshot running as
  `postgres` that runs `CREATE EXTENSION IF NOT EXISTS vchord CASCADE;`,
  ordered `before` and `required by` `immich-server`. It is a no-op on a normal
  boot; it matters if the DB is ever restored from a pre-migration dump, and it
  documents why the extension exists outside NixOS (the `immich` role owns the
  DB but is not a superuser, and `services.immich.database` is off).

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

**Reboots are the one step the rollback cannot cover** — if the kernel does not
boot, no timer runs. That gap was closed by testing it deliberately: the 26.11
move brought 6.12.77 → 6.18.57, and on **2026-11-26 22:59** the box was
cold-booted onto 6.18.57 with `system-good` armed at the 25.11 generation
(`sudo nixos-confirm 172` → reboot → confirm once back; without that confirm it
reverts to 25.11 and reboots). Result: back in ~65 s, tailscaled `Running` 12 s
after start **without using the pre-auth key** (the persisted
`/var/lib/tailscale/tailscaled.state` carried the node identity —
`tailscaled-autoconnect` logs "Tailscale is running" and exits), all nine
containers healthy, public HTTPS 200 on both vhosts, ZFS pools imported, zero
failed units. The 25.11 generation stays in the systemd-boot menu as a manual
fallback.

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

The 25.11 `/home/cjdell`-era configs are gone from the flake: roll back a live
mistake by generation (`sudo nixos-rebuild switch --rollback`, or
`nixos-confirm <gen>`), not by rebuilding an old output.

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

1. `common/system.nix` + `users/cjdell` — requires an `enable` switch on
   `common/build-client.nix` (or a colin-specific override) because colin must
   not dispatch builds to zen3.
2. `boot.zfs.forceImportRoot = false` (26.11 recommends it; silence the eval
   warning deliberately, not by accident).
