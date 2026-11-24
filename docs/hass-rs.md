> Archived from AGENTS.md (2026-11-24). The short version lives in AGENTS.md; this file holds the full backstory.

## hass-rs shadow hub (grafton-router, shadow mode)

`crates/home-assistant-rust` (upstream `cjdell/home-assistant-rust`) is a
Rust rewrite of Home Assistant core that runs **beside** the real HA container
on grafton-router. It is a git submodule, and Nix's git fetcher omits
submodule contents, so the infra flake consumes it as the
`home-assistant-rust` **`git+file`** input (`flake = false`) — not a plain
`path:` input, so a local cargo `target/` never lands in the lock. After
editing the submodule:

```sh
git -C crates/home-assistant-rust add -A && git -C crates/home-assistant-rust commit
nix flake update home-assistant-rust
```

`hosts/grafton-router/services/hass-rs.nix` callPackages its
`nix/package.nix` with `craneLib = inputs.crane.mkLib pkgs` and runs it as
user `hass-rs` (group `users`):

- **Config** is a `linkFarm`: a generated `configuration.yaml` with
  Mosquitto at `192.168.49.1:1883` (client id `hass-rs-shadow`) and a
  `.storage` symlink to `/srv/homeassistant/config/.storage`. Areas,
  entity/device ids and `core.restore_state` are therefore imported
  read-only from the live HA install; hass-rs never writes them.
- **Ports:** HA-compatible API on `127.0.0.1:8126` (loopback only; not
  proxied; 8124 is zigbee2mqtt's web UI), dashboard on `127.0.0.1:8125`.
- **Dashboard:** `https://hass-rs.home.chrisdell.info` → nginx → `:8125`.
  It is server-rendered (Topcoat, pinned 0.6.2) and has **no login**; nginx
  allow-lists `LAN_SUBNET`, `VLAN10_SUBNET`, `WIREGUARD_SUBNET`,
  `TAILSCALE_SUBNET` and the LAN `/64`, then `deny all`. That is the whole
  authentication story — do not remove the allow-list.
- **Shadow mode:** `--no-automations`; the real HA owns the automations.
  Buttons/sliders *do* publish to `zigbee2mqtt/<dev>/set`, so do not click
  them in smoke tests.
- Deploy on the router:
  `sudo nixos-rebuild switch --flake . && sudo nixos-confirm`
  (autoRollback is on). Evaluation is local (zen3 cannot evaluate this flake
  because of the `frigate-monitor` path input); builds dispatch to zen3.
  Logs: `journalctl -u hass-rs -f`.

