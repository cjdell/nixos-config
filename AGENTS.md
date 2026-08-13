# AGENTS.md

Guidance for AI coding agents working in this repository. Read this before making changes.

## Repository overview

A NixOS flake-based configuration managing many hosts (NAS boxes, ThinkPads, a Zen 3 GPU
workstation, etc.). Key layout:

| Path | Purpose |
| --- | --- |
| `flake.nix` | Flake definition; builds every `hosts/<name>` dir as a NixOS config |
| `hosts/` | Per-host configuration. **Directory name == host name** (e.g. `zen3-nixos`) |
| `common/` | Shared modules (`system.nix`, `desktop.nix`, `sops.nix`, …) |
| `users/` | User configs (home-manager) |
| `machines/` | Legacy configs for older machines (referenced from `flake.nix`) |
| `llama-log-viewer/` | Standalone zero-dependency Rust web app (see below) |
| `llama-logs/` | Live `llama-server --log-prompts-dir` output consumed by the viewer |
| `secrets/` | sops-encrypted secrets |
| `scripts/` | Install/PXE helper scripts |

Formatting: `./format.sh` runs `nixfmt` over all `.nix` files.

## Critical: auto-rollback + `nixos-confirm` (READ THIS FIRST)

`system.autoRollback.enable = true` is set on **multiple hosts**, including
`zen3-nixos` (`hosts/zen3-nixos/default.nix`) and `N100-NAS`
(`hosts/N100-NAS/default.nix`). It comes from the `nixos-utils` flake input
(`github:cjdell/nixos-utils`, module `nixos-utils.nixosModules.rollback`).

How it works:

- An `auto-rollback.timer` fires **5 minutes after every activation**.
- It runs `auto-rollback-start`, which compares `/run/current-system` against
  the symlink `/nix/var/nix/profiles/system-good`. If they differ, it
  broadcasts a 30-second warning, runs `switch-to-configuration boot` on the
  good generation, and **reboots the machine** (`echo b > /proc/sysrq-trigger`).
- `system-good` is only updated by `nixos-confirm` (see below).

**Consequence:** after **every** `nixos-rebuild switch` or `boot` on such a
host, you must run:

```sh
sudo nixos-confirm
```

`nixos-confirm` (already on PATH via `systemPackages`):
1. Stops `auto-rollback.service` and `auto-rollback.timer`.
2. Points `/nix/var/nix/profiles/system-good` at the current generation.

You can also pass a generation number: `sudo nixos-confirm 189`.

> Failure to confirm means the host will roll itself back (and reboot!) within
> ~5 minutes of the rebuild. This can silently undo your changes — the
> `llama-log-viewer` service, nginx config, and everything else reverts to the
> last *confirmed* generation.

## Building and deploying

Per-host rebuilds use the flake; the canonical commands (from `flake.nix` header):

```sh
sudo nixos-rebuild boot   --impure --flake . --max-jobs 1
sudo nixos-rebuild switch --impure --flake . --max-jobs 1
```

- `--impure` is required (config reads the live system, e.g. UIDs).
- `--max-jobs 1` keeps builds light on the target host (commonly used on
  machines with limited RAM); the whole flake evaluates all ~20 hosts either way.
- Always follow with `sudo nixos-confirm` on hosts that enable autoRollback
  (see above).
- Avoid running `nix build`/`nixos-rebuild` for heavy jobs unless the task
  calls for it; the user often deploys manually.

## The live target host: `zen3-nixos`

This is the machine the repo lives on (`192.168.49.50`). It runs:

- **llama-server** via `llama-swap` on `127.0.0.1:8081` (model serving)
- **llama-log-viewer** on `127.0.0.1:8083` (the web app in this repo)
- **diamcp** container on `127.0.0.1:8082` (OCI container, podman)
- **nginx** (from `netboot.nix` + `ai.nix`) exposing all of it on port 80
  - `server_name 192.168.49.50` → `/` → 8081, `/logs` → 8083, `/mcp` → 8082
  - the app is reachable at `http://192.168.49.50/logs/`

## llama-log-viewer

`llama-log-viewer/` is a **zero-dependency Rust** app (stdlib only — no crates
in `Cargo.toml`). Frontend (`index.html`, `app.js`, `style.css`) is embedded
into the binary via `include_str!`.

- **Any frontend change requires rebuilding the Rust binary** (the served
  files come from the compiled binary, not the repo dir on disk).
- The index (trie over message sequences) is rebuilt on demand when new log
  files appear; stats show e.g. `496 files / 1743 nodes / 24 roots`.
- Log files: one `.txt` per API call containing the complete context; formats
  handled: Qwen `<|im_start|>` and opencode `<system>…</system>` style.
- See `llama-log-viewer/README.md` for API endpoints and design.

Rebuild + deploy on `zen3-nixos` (used successfully in the past):

```sh
# the nix package is built from this dir by hosts/zen3-nixos/ai.nix
# (pkgs.rustPlatform.buildRustPackage with cargoLock.lockFile)
sudo nixos-rebuild switch --impure --flake . --max-jobs 1
sudo nixos-confirm
```

## Known gotchas on this host

- **`sudo nginx -T` is misleading** — it reads the package's stock
  `conf/nginx.conf`, NOT the NixOS-generated config under
  `/nix/store/<hash>-nginx.conf`. To see the real config, pass it explicitly:
  `sudo nginx -T -c "$(grep -o '/nix/store/[a-z0-9]*-nginx.conf' /run/current-system/etc/systemd/system/nginx.service/nginx.service)"`.
- The NixOS nginx unit runs `daemon off` under systemd (foreground).
  Standalone nginx tests need patched `pid`/`error_log`/`access_log` paths,
  ports, and `setsid`/`nohup` to background.
- The `llama-log-viewer` systemd service runs **as root** because
  `/home/cjdell` is `700` — a non-root user cannot read
  `/home/cjdell/nixos-config/llama-logs`.
- `python3` is **not** on PATH; use `nix shell nixpkgs#python3 --command …`.
- Rust: `cargo 1.95` is on PATH but `rustc` is broken; use
  `rustup run stable cargo build --release` with the gcc wrapper from the
  system (`PATH=/nix/store/<gcc-wrapper>/bin:$PATH`) if you must build the app
  outside Nix. Prefer `nixos-rebuild` to build the packaged binary.
- The nginx `/logs` route strips its prefix with an explicit rewrite
  (`rewrite ^/logs/?(.*)$ /$1 break;` + `proxy_pass http://127.0.0.1:8083;`).
  The earlier trailing-slash `proxy_pass …/;` variant was observed *not* to
  strip on the live master; the explicit rewrite is the form that works.

## Workflow conventions

- Do not run heavy builds unless the task requires it; the user applies Nix
  config themselves when they prefer.
- If you DO apply a config (with permission), always finish with
  `sudo nixos-confirm` on autoRollback hosts.
- The repo often has uncommitted/staged changes (e.g. `ai.nix`, `default.nix`)
  plus untracked scratch files (`dump.txt`, `logs.txt`, `ppp.sh`, `result*`).
  Leave them alone unless the task is about them.
