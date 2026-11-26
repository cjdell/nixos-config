# colin

ElectroNerds home server at `192.168.178.10` (`electronerds.com`), adopted
into the fleet on 2026-11-26 from its standalone single-host flake. **Its role
is unchanged**: AdGuard, Frigate, Home Assistant, Jellyfin, Immich, filebrowser,
qBittorrent, UniFi, Whoogle, LibreSpeed, Samba, Mosquitto, Postgres, its own
nginx/ACME Route53 edge, the WireGuard client, Tailscale/headscale and the
`create_ap` Wi-Fi AP, all on the `electronerds` ZFS pool.

## Why this host is different

- **Satellite site.** It lives on `192.168.178.0/24` behind TalkTalk, not on the
  fleet's `192.168.49.0/24` LAN, and cannot reach the zen3 builder
  (`192.168.49.50`). It must build locally; do **not** import
  `common/build-client.nix`.
- **Ported verbatim.** `hosts/colin/default.nix` is the old flake's module list
  in the same order, and `flake.nix` pins `nixpkgs_25_11` to the exact rev the
  live system was built from (`25.11.20260324.1073dad`). The verbatim port
  evaluated to the running system bit-for-bit
  (`3afzvxf0bkbfr7np9qdn4z4rhqj5njiw-nixos-system-colin-25.11.20260324.1073dad`).
- **Not fleet-native yet.** It deliberately does not use `common/system.nix`,
  `users/cjdell`/home-manager config, autoRollback or the fleet's
  nixos-unstable pin. Converging it is a separate, testable change.

## Secrets

Secrets live in `hosts/colin/secrets/secrets.yaml` (sops), encrypted to the
fleet age key. `/var/lib/sops-nix/key.txt` must exist on the host; sops renders
`/run/secrets/*` and `/run/secrets/rendered/*` (Route53 env, htpasswd,
`create_ap.conf`) at activation, so nothing secret is in `/nix/store`.
`sops-nix_25_11` is pinned to the last pre-Go-1.26 revision because
nixos-25.11's toolchain cannot build newer `sops-install-secrets`.

## Rebuild

```sh
sudo nixos-rebuild switch --flake .        # hostname is colin, so this picks .#colin
# or
sudo nixos-rebuild switch --flake .#colin
```

The old repo's `mariadb.nix` and `photoprism.nix` were never imported and
referenced constants that do not exist, so they are intentionally not ported
(they remain in `~/nixos-config.pre-fleet-2026-11-26`).
