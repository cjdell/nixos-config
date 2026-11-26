# colin

ElectroNerds home server at `192.168.178.10` (`electronerds.com`), adopted
into the fleet on 2026-11-26 from its standalone single-host flake. **Its role
is unchanged**: AdGuard, Frigate, Home Assistant, Jellyfin, Immich, filebrowser,
qBittorrent, UniFi, Whoogle, LibreSpeed, Samba, Mosquitto, Postgres, its own
nginx/ACME Route53 edge, the WireGuard client, Tailscale/headscale and the
`create_ap` Wi-Fi AP, all on the `electronerds` ZFS pool.

## Why this host is different

- **Satellite site.** It lives on `192.168.178.0/24` behind TalkTalk, not on the
  fleet's `192.168.49.0/24` LAN. Since 2026-11-26 it *does* reach that LAN over
  the tailnet (`--accept-routes`, see `./wireguard.nix` and *Reaching the fleet
  LAN* below), but it still builds locally: `fleetBuildClient.enable = false`
  in `./default.nix` turns `common/build-client.nix` off for this host only, so
  fleet builds don't have to cross the TalkTalk WAN.
- **Two things it does not take from the fleet**: `common/sops.nix` (its sops
  file and secret set are its own — `./sops.nix` — so it cannot share the
  fleet's `defaultSopsFile`) and the fleet `sharedPackages` list alone (it adds
  the disk/network forensics tools it actually uses).
- **Everything else is shared**, because it is now a normal `hosts/colin`
  directory built by flake.nix's `mkHost`.

## Reaching the fleet LAN (192.168.49.0/24, added 2026-11-26)

The LAN is reachable from here **through the tailnet, not the WAN**: grafton-router
is a tailscale subnet router advertising `192.168.49.0/24` (plus `10.3.0.0/16`
and the hackspace IPv6 /48s), and `./wireguard.nix` now passes
`--accept-routes=true` instead of `false`. Tailscale installs the accepted
routes in its own table 52 (priority 5270, ahead of `main`); `100.64.0.0/10`
and this host's local subnets are untouched, so an SSH session arriving over
`tailscale0` keeps its return path.

Apply the flag on a live box (before the rebuild that makes it survive a reboot):

```sh
sudo tailscale set --accept-routes=true     # instant, no tailscaled restart
ip route show table 52 | grep 192.168.49    # expect: 192.168.49.0/24 dev tailscale0
ping -c2 192.168.49.50
```

Without the rebuild, the next boot's `tailscaled-autoconnect` re-runs
`tailscale up --accept-routes=false` and the flag silently reverts. The rebuild
only restarts `tailscaled-autoconnect`, never `tailscaled` itself, so it does
not drop an SSH session — but `nixos-confirm` is still required afterwards.

## Unification status (begun 2026-11-26, finished 2026-11-26)

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
- **Full mkHost adoption** (2026-11-26, second and last step). `colin` is no
  longer a bespoke `nixosSystem` block in `flake.nix`; it is discovered as a
  `hosts/colin` directory like every other host, so it now gets
  `common/system.nix` (fleet CLI set, ssh, nix-ld, sudo, `en_GB` locale,
  `stateVersion 24.11`, `mitigations=off`), `users/cjdell` + home-manager with
  `homeManagerPrefs`, and `commonModules` (nixos-utils rollback + containers).
  `common/build-client.nix` gained a `fleetBuildClient.enable` option (default
  true) precisely so this host can keep building locally.
- Housekeeping that came with it: colin's package list is now only the extras
  on top of `sharedPackages`; the duplicated ssh/sudo/nix-ld/timezone/
  stateVersion/experimental-features settings are gone (the shared modules own
  them); its hand-rolled `update-containers` unit/timer is gone in favour of
  the fleet `system.updateContainers` one (**daily 02:00** with the notify
  webhook, instead of Monday 02:00); `boot.zfs.forceImportRoot = false` is set
  deliberately; and `containers.nix` no longer imports a non-existent
  `../constants.nix` (the binding was unused, so it had never been evaluated).

**Activated 2026-11-26 23:24** (generation 176 → `wjf4hcy…` after the
librespeed fix below), `nixos-confirm`ed, and verified live:

- all nine containers up; 13/13 nginx vhosts answer (200/301/302 — a 502 on
  `speed.` was a real port bug, see below);
- `tailscaled` Running with the persisted node identity (no pre-auth key used),
  `sshd`, `nginx`, `postgresql`, `immich-server`, `mosquitto`, `samba-smbd`,
  ACME all active; ZFS `electronerds` ONLINE 90 %; zero failed units;
- home-manager took over `/home/cjdell`: `~/.config/opencode/{opencode,cli}.json`,
  `~/.config/git/config`, `~/.npmrc` are store symlinks, `home-manager-cjdell`
  exited 0;
- activation itself reported `status 4` once, on a **transient** unifi
  `podman healthcheck run` unit that raced the container's own startup — a
  `systemctl reset-failed` + re-run passed. Not an activation failure.
- **`speed.electronerds.com` was a 502 for a pre-existing reason**, not the
  unification: the `ghcr.io/librespeed/speedtest` image defaults `WEBPORT` to
  8080 while the publish and nginx use container port 80. Fixed with
  `WEBPORT = "80"` in `services/librespeed.nix` (`speed` now 200).

### What changed for the people using it

- `LANG`/`LC_*` moved from `en_US.UTF-8` to the fleet's `en_GB.UTF-8` (log in
  again — an existing shell keeps its old locale).
- `cjdell` is now in `networkmanager`, `dialout`, `i2c` and `video` as well as
  `wheel` (fleet `users/cjdell`), and **home-manager manages
  `/home/cjdell`** from the first switch: `~/.config/opencode` is taken over
  (`force = true`, any previous files are moved aside as `.backup-<n>`), plus
  `~/.config/git/config`, `~/.npmrc` and nodejs in the user profile.
  `~/.opencode` itself is untouched (installer-managed binary).
- `mitigations=off` is now in the kernel command line (takes effect on the next
  boot), like every other fleet host.



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
*module* is imported by `./default.nix` (`sops-nix.nixosModules.sops` — it is
not part of `mkHost`, since each host pulls it from the flake inputs), and the
settings are in `./sops.nix`.

## Rebuild

```sh
sudo nixos-rebuild switch --flake .        # hostname is colin, so this picks .#colin
sudo nixos-confirm                          # REQUIRED within 5 minutes
```

`sudo nixos-rebuild …` is the correct form: nixos-rebuild-ng re-runs the flake
evaluation as the invoking user (`cjdell`), which is what the libgit2 ownership
check needs. Invoking the same rebuild **as root** (`sudo systemd-run …
nixos-rebuild`, a root cron job, `su -`) fails with
`repository path '/home/cjdell/nixos-config' is not owned by current user` —
evaluation as root never reaches the build, so don't "fix" it by chowning the
checkout. If a switch must survive an SSH drop, run it detached as cjdell with
`PATH` set, or arm `scripts/remote-rebuild-guard.sh` and activate by hand
(`nix-env -p /nix/var/nix/profiles/system --set <toplevel>` then
`<toplevel>/bin/switch-to-configuration switch` as root).

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

None for the adoption itself. Deliberate differences that will stay:

1. `fleetBuildClient.enable = false` — no network path to zen3 (see above).
2. `./sops.nix` instead of `common/sops.nix` — colin's own secrets file; it
   never had the fleet `brave_api_key` secret, which is fine (the opencode
   brave MCP server just fails to start there, exactly as on the other
   sops-less hosts).
3. Its own `hardware-configuration.nix`, `http.nix` (nginx/ACME Route53 edge,
   `electronerds.com`), `wireguard.nix`, `networking.nix` (`create_ap`, NAT,
   the ping-reboot watchdog) and `services/` — that is the host's role, not
   drift.

