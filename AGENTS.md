# AGENTS.md

Guidance for AI coding agents working in this repository. Read this before making changes.

This file is the **index**. Full backstory for each topic lives in `docs/` — read the linked doc when you need the details.

## Step 0: identify the host you are on — before anything else

**Do not assume you are on zen3-nixos.** This repo is checked out on several
machines — verified 2026-10-08: `~/nixos-config` exists on **zen3-nixos,
grafton-router, N100-NAS, GEN8-NAS and N40L-NAS** (plus alderlake-thinkpad and
the MacBookAir, where the rebuild is `just switch`, and since 2026-10/11 also
haswellatx-nixos, asus-i7-6700-nixos and kabylakeitx-nixos, and since 2026-11-15
hp-z240-xeon-1240v6-nixos, and since 2026-11-18 asus-x555la-nixos (clone
pushed to it from zen3 over the LAN — it has no GitHub key of its own) — and the flake evaluates/builds *every* host from
*any* of them. Start by asking where you are:

```sh
hostname                      # == the hosts/<name> directory == the flake attribute
ip -4 addr show scope global  # which segment you are on (192.168.49.0/24 = LAN)
```

Then act on the answer:

- **`nixos-rebuild switch --flake .` without `--target-host` reconfigures the
  machine you are standing on**, not the one you were thinking about. On an
  autoRollback host a forgotten `sudo nixos-confirm` then reboots *that* box ~5
  min later. Name the host you are deploying to in your reply before you do it.
- **Host-specific state does not exist elsewhere**, and querying it on the wrong
  host returns nothing and looks like a bug. zen3-nixos: the AI stack (`strata`,
  `llama-swap`, `sd-server`, Recallium, diamcp, llama-log-viewer),
  `/home/cjdell/Models`, `llama-logs/`, the R9700 (`amd-smi`), `/etc/tftp` +
  `/exports` (Pi 5 netboot), zram. grafton-router: `meter-relay`, dnsmasq leases,
  kanidm, Home Assistant, Frigate, WireGuard/headscale, the public nginx edge.
  N100-NAS: Jellyfin, Immich, Grafana, Postgres, qBittorrent. 3d-printer-server:
  the `podman-klipper` units.
- **Toolchains differ**: grafton-router has no `cargo`, `rustc` or `cc`; no host
  has `python3` on PATH; GPU tooling exists only on the GPU boxes; `nixos-confirm`
  only matters where `system.autoRollback` is on (see *Critical: auto-rollback +
  `nixos-confirm`* below).
- **The working tree is not the running system.** Check
  `git -C ~/nixos-config log -1 --format='%cd %s'` and `git status` against
  `/run/current-system` (or a `nixos-rebuild … dry`) before concluding a change
  is deployed — and remember `path:` flake inputs are frozen at their
  `flake.lock` `narHash`.
- If the task names a host you are **not** on, reach it over SSH with a
  `timeout` (`ssh <host>.grafton.lan` on the LAN, `<host>.grafton.tailscale` on
  the tailnet) instead of running the command locally, and say which host each
  result came from.


## Repository overview

A NixOS flake-based configuration managing many hosts (NAS boxes, ThinkPads, a Zen 3 GPU workstation, etc.). Key layout:

| Path | Purpose |
| --- | --- |
| `flake.nix` | Flake definition; builds every `hosts/<name>` dir as a NixOS config |
| `hosts/` | Per-host configuration. **Directory name == host name** (e.g. `zen3-nixos`) |
| `common/` | Shared modules (`system.nix`, `desktop.nix`, `sops.nix`, …) |
| `users/` | User configs (home-manager) |
| `machines/` | Legacy configs for older machines (referenced from `flake.nix`) |
| `crates/` | Every Rust crate in this repo (`llama-log-viewer`, `gpu-panel`, `ollama-bridge`, `meter-relay-rs`), built by the root flake |
| `footage/` | Video cleanup kit: `footage-clean`/`footage-probe` CLI. `nix build .#footage-kit`, usage in `footage/README.md` |
| `llama-logs/` | Live `llama-server --log-prompts-dir` output consumed by the viewer |
| `secrets/` | sops-encrypted secrets |
| `scripts/` | Install/PXE helper scripts, plus `scripts/gpu-probe/` (see its README) |

Formatting: `./format.sh` runs `nixfmt` over all `.nix` files.

## The servers on the network (who runs what)

All in `hosts/<name>`, on the `192.168.49.0/24` LAN with domain `grafton.lan`; tailnet names are `<host>.grafton.tailscale`. Static leases are in `hosts/grafton-router/networking/dns.nix` — that file is the network map.

| Host | LAN IP | Role |
| --- | --- | --- |
| **grafton-router** | `.1` | Edge router + main homelab app host (kanidm, Home Assistant, Frigate, Jellyfin, meter-relay, nginx edge, …). **autoRollback ON** |
| **zen3-nixos** | `.50` | AI workstation + primary build box (Strata/Avalon, sd-server, Recallium, diamcp, llama-log-viewer, gpu-panel, nginx `*.ai.chrisdell.info`). autoRollback commented out |
| **N100-NAS** | `.22` | Media/app NAS (Jellyfin, Immich, Silo, Grafana, qBittorrent, Postgres). **autoRollback ON** |
| **GEN8-NAS** | `.23` | Bulk file + snapshot host (Samba/NFS, sanoid/syncoid) |
| **N40L-NAS** | `.21` | Backup target (ZFS `sas-16tb`) |
| **zen1-nixos** | `.51` | folding@home space heater (Ryzen 1800X + RX 5700 XT) |
| **haswellatx-nixos** | `.54` | folding@home space heater + Plasma console (i5-4460, R9 290/390) |
| **3d-printer-server** | `.60` | Klipper 3-D-print server (Smoothieboard) |
| **asus-i7-6700-nixos** | `.65` | folding@home space heater + Plasma console (i7-6700, GTX 1060 + 970) |
| **kabylakeitx-nixos** | `.55` | folding@home space heater + video workbench (i7-7700, RTX 2060) |
| **asus-x555la-nixos** | `.70` | e-waste ASUS X555LA laptop (adopted 2026-11-18, no role yet) |
| **hp-z240-xeon-1240v6-nixos** | `.59` | folding@home space heater (Xeon E3-1240 v6, GTX 1060 console) |
| **colin** | `.10` on `192.168.178.0/24` (satellite site, not the fleet LAN) | ElectroNerds home server: AdGuard, Frigate, Home Assistant, Jellyfin, Immich, filebrowser, qBittorrent, UniFi, Whoogle, LibreSpeed, Samba, Mosquitto, Postgres, own nginx/ACME edge, WireGuard client, `create_ap` AP. **Fully unified 2026-11-26** (fleet pin, `common/system.nix` + `users/cjdell` via `mkHost`, Immich 3.3.3 + VectorChord; no 25.11 pins left); `system.autoRollback` ON; **builds locally** — `fleetBuildClient.enable = false`. Since 2026-11-26 it *does* reach the fleet LAN (`192.168.49.0/24`) — over the tailnet, via grafton-router's subnet routes (`--accept-routes=true` in `hosts/colin/wireguard.nix`), not the WAN. See `hosts/colin/README.md` |
| **pi5** | `.92` | aarch64 netboot node — **currently off** (netboot imports commented out) |

Full per-host backstory (what each actually runs, deploy notes, gotchas): **`docs/hosts.md`**.

Load-bearing hosts **not** in this flake: **dbthr33-server** (offsite backup target), **inverter-pi** `.30` (`ser2net` Modbus-RTU bridge for meter-relay), zigbee `.31`, jk-bms-can `.32`/`.33`, the OpenWrt APs `.2`/`.3`, and the **MacBookAir-NixOS** aarch64 build machine (`192.168.49.69`, MAC `00:0e:c6:8e:b3:ff`).

Clients, not servers: `alderlake-thinkpad`, `rocketlakelatitude`, and the legacy `machines/*` configs.

## Deploying an update to a host that cannot build it (NAS boxes, router)

Since 2026-10-17 every host in this flake uses zen3-nixos as a remote Nix builder, so `nixos-rebuild switch --flake .` run **on** a NAS/router dispatches its builds to zen3. The closure-streaming procedure below is no longer the only option — it remains useful when the target cannot reach zen3, or when you want to guarantee the exact toplevel you built here.

- **SSH to the NAS hosts:** `cjdell` with key `~/.ssh/id_ed25519_ps` (passwordless sudo). The default `id_ed25519` is *not* authorized there. None of the three has GitHub credentials of its own, so update their checkouts with **agent forwarding**: `ssh -A -i ~/.ssh/id_ed25519_ps cjdell@<nas> "cd nixos-config && git pull --ff-only"`.
- **`nix copy --to ssh://cjdell@nas` fails** — `cjdell` is not a trusted user on any NAS. Instead build the toplevel on zen3 and stream the closure *delta* into the NAS store as root: `nix-store -qR <toplevel>` (zen3) vs `nix-store -qR /run/current-system` (NAS), `comm -23` the two lists, then `nix-store --export $(cat delta) | zstd -T2 -3 | ssh cjdell@nas 'zstd -d -q | sudo -n nix-store --import'` (~6 GB per host, a few minutes on the LAN), then on the NAS `sudo nix-env -p /nix/var/nix/profiles/system --set <toplevel>` and `sudo <toplevel>/bin/switch-to-configuration switch`. `nixos-confirm` afterwards on **N100-NAS** only.
- **A kernel bump means the ZFS module only loads on the next boot** — reboot each ZFS host to actually move onto the new kernel.
- **grafton-router cannot be *evaluated* on zen3 at all**: `frigate-monitor` is a `path:/home/cjdell/Projects/frigate-monitor` flake input that exists only on the router. Rebuild it on the router — evaluation happens on the router and only the derivations go over ssh-ng.
- **kanidm** is `pkgs.kanidm_1_11.withSecretProvisioning` (1.11.2, domain level 15). Kanidm only migrates **one minor version at a time** — the next bump must be 1.11 → 1.12. Procedure: tar `/var/lib/kanidm` with the service stopped, run `kanidmd domain upgrade-check -c <server.toml>` **while the old server is running**, then `nixos-rebuild switch`. Verify with the OIDC discovery endpoint and `ldapwhoami -H ldaps://kanidm.home.chrisdell.info:8998 -x`.

## Critical: auto-rollback + `nixos-confirm` (READ THIS FIRST)

`system.autoRollback.enable = true` is set on **N100-NAS**, **grafton-router** and **colin** (live since 2026-11-26 — colin is internet-only, so this is its remote safety net). It is **commented out (disabled) on zen3-nixos**. The module comes from the `nixos-utils` flake input.

- An `auto-rollback.timer` fires **5 minutes after every activation**.
- It runs `auto-rollback-start`, which compares `/run/current-system` against the symlink `/nix/var/nix/profiles/system-good`. If they differ, it broadcasts a 30-second warning, runs `switch-to-configuration boot` on the good generation, and **reboots the machine**.
- `system-good` is only updated by `nixos-confirm`.

**Consequence:** after **every** `nixos-rebuild switch` or `boot` on such a host, you must run:

```sh
sudo nixos-confirm
```

`nixos-confirm` (already on PATH via `systemPackages`): stops `auto-rollback.service` and `auto-rollback.timer`, and points `/nix/var/nix/profiles/system-good` at the current generation. You can also pass a generation number: `sudo nixos-confirm 189`.

> Failure to confirm means the host will roll itself back (and reboot!) within ~5 minutes of the rebuild.

## Building and deploying

Per-host rebuilds use the flake; the canonical commands:

```sh
sudo nixos-rebuild boot   --flake .
sudo nixos-rebuild switch --flake .
```

- **`--impure` is no longer needed** — the flake evaluates in pure mode. Don't reintroduce `--impure` unless a genuinely impure read comes back.
- **Deploy locally when you're already on the target host:** check `hostname` first — if it matches the target host name, the flake is checked out on this machine, so run the rebuild here.
- **zen3-nixos (192.168.49.50) is the fleet's build server**: `common/build-client.nix` sets `nix.distributedBuilds` + one ssh-ng `nix.buildMachines` entry (root@zen3, 16 jobs, `speedFactor 4`) and keeps `nix.settings.max-jobs = mkDefault 1` — one local build slot as a fallback. The module self-disables on zen3, which builds locally (`max-jobs = 16`) and dispatches aarch64-linux to the MacBookAir via its own entry. **`publicHostKey` is the bare Base64 key body**, not `ssh-ed25519 AAAAC3…`.
- **Onboarding a build client**: on the client `sudo ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N ''`, add the printed public key to `users.users.root.openssh.authorizedKeys.keys` in `hosts/zen3-nixos/default.nix`, rebuild zen3, then rebuild the client. A client whose key is not authorized silently falls back to local builds — that's the symptom. NixOS writes `openssh.authorizedKeys.keys` to **`/etc/ssh/authorized_keys.d/<user>`**, not `~/.ssh/authorized_keys`. The real client-side check is `sudo cat /etc/nix/machines`.
- Always follow with `sudo nixos-confirm` on hosts that enable autoRollback.
- **Local `path:` flake inputs freeze at the `narHash` in `flake.lock`.** Editing such a checkout changes *nothing* until `nix flake update <name>` rewrites that lock entry. A `path:` input also copies the WHOLE directory into the store — `target/` and `.git` included — so prefer `git+file://` for any local input with a build tree in it. In a flake's *own* checkout Nix reads the git tree instead, so a new file must be at least staged (`git add`) or it is invisible to the build.
- Avoid running `nix build`/`nixos-rebuild` for heavy jobs unless the task calls for it; the user often deploys manually.
- **`hosts/grafton-router/secrets/` looks ignored but is tracked.** The root `.gitignore`'s `secrets/` has no leading slash, so it matches at *any* depth — yet `hosts/grafton-router/secrets/secrets.yaml` is in HEAD. `git add` on it prints "The following paths are ignored … use -f" **and exits 1**, while quietly staging it correctly: in a `git add … && git commit` chain the commit never runs. Check `git status` rather than trusting the exit code, and use `git add -f` for a genuinely *new* file under there.

## The live target host: `zen3-nixos`

The repo lives here (`192.168.49.50`). It runs the AI stack: Strata (or Avalon, disabled) on `:8080`, sd-server (Flux-schnell) on `:8085`, Recallium, diamcp, llama-log-viewer, gpu-panel, nginx `*.ai.chrisdell.info`. Full details — llama-swap (disabled), the `-cram` OOM history, nginx layout, public HTTPS, the `/api/` split — in **`docs/zen3-nixos.md`**.

## Pi 5 netboot (aarch64) — currently switched OFF

A headless Raspberry Pi 5 network-boots NixOS from zen3. **None of this is deployed at the moment** (netboot imports commented out of `hosts/zen3-nixos/default.nix` since `dc54f4a`). Full journey + gotchas: **`docs/pi5-netboot.md`**.

## 3d-printer-server (Klipper on a Smoothieboard, live)

Host `3d-printer-server` = `192.168.49.60` (no autoRollback). Runs the `mkuf/prind` Klipper stack as three rootful podman units with Mainsail on nginx :80. Board is a **Smoothieboard (LPC1768)**.

- **Full runbook: `docs/klipper-3d-printer.md`.** Read it before touching this host.
- **MCU firmware:** `sudo klipper-firmware-update [--status|--to-sd DIR|--flash]` — the container tracks the floating `latest` tag and re-pulls on every start, so the host version drifts silently while the flashed firmware doesn't change.
- **"Mainsail doesn't load" is usually not a Mainsail problem** — klippy wedges and Moonraker's requests hang 60 s. Recovery: restart `podman-klipper` + `podman-moonraker`, then `FIRMWARE_RESTART`.
- **Open fault:** both thermistor readings sit at a stable but wrong ~81/86 °C and don't respond to heating. Leading suspect: the analog rail feeding the thermistor pullups. **Do not leave a heater running** — with an in-range-but-wrong reading Klipper holds 100 % duty and `max_temp` can't trip.

## llama-log-viewer

`crates/llama-log-viewer/` is a **zero-dependency Rust** app (stdlib only). Frontend (`index.html`, `app.js`, `style.css`) is embedded into the binary via `include_str!`.

- **Any frontend change requires rebuilding the Rust binary** (the served files come from the compiled binary, not the repo dir on disk).
- The index (trie over message sequences) is rebuilt on demand when new log files appear.
- Log files: one `.txt` per API call containing the complete context; formats handled: Qwen `<|im_start|>` and opencode `<system>…</system>` style.
- See `crates/llama-log-viewer/README.md` for API endpoints and design.

Rebuild + deploy on `zen3-nixos`:

```sh
sudo nixos-rebuild switch --flake . --max-jobs 1
sudo nixos-confirm
```

## stable-diffusion-cpp + sd-server + gpu-mode (zen3-nixos)

`stable-diffusion-cpp` is installed as a **Vulkan build** (nixpkgs default is CPU-only). Since 2026-11-06 the service runs **FLUX.1-schnell**; SDXL remains on disk for ad-hoc `sd-cli` use. `sd-server` (`hosts/zen3-nixos/ai/sd-server.nix`) runs on `127.0.0.1:8085`, no `wantedBy` — `gpu-mode sd` starts it and waits until `GET /v1/models` answers.

`gpu-mode` (`hosts/zen3-nixos/ai/gpu-mode.nix` + `./gpu-mode.sh`) makes the 32 GiB card a **lease**: `llm` (boot default, stops sd-server, starts strata, waits for `/v1/status` `loaded:true`), `sd` (stops strata, starts sd-server), `game`/`free`/`off` (stops both). The lease is exclusive by *unit state* — sd/game **stop** `strata.service` outright, so background traffic cannot auto-reload the 90 GB model into VRAM mid-game.

Full details (weights, schnell recipe, VAE-tiling gotcha, SDXL test command, lease semantics): **`docs/sd-server.md`**.

## LFM3-1.7B on the RX 580 (`lfm3.service` — the second-card lane)

`hosts/zen3-nixos/ai/lfm3.nix`: stock llama.cpp **Vulkan** serving `LFM3-1.7B-Q4_K_M.gguf` on the **RX 580 = the console GPU** (`1002:67df`). Loopback `127.0.0.1:8086`; `lfm3.ai.chrisdell.info` (UI + API) and `/lfm3/` on the IP vhost.

- **Not part of the `gpu-mode` lease** — the unit pins `MESA_VK_DEVICE_SELECT=1002:67df!`, so the R9700 is invisible to it. Always on (`wantedBy`).
- **Server-side tools are ON** (`--tools all`) with `--tools-runtime podman:docker.io/library/python:3.11-slim` — **never drop the runtime flag on a reachable endpoint** (without it the tools execute as root). The unit needs `path = [ pkgs.podman ]`.
- The `lfm3.ai.chrisdell.info` vhost is allow-listed to LAN/VLAN10/WG/tailnet + the LAN /64 + leighhack's `2001:8b0:1d14::/48` (`deny all`).

Full details (ctx sizing, measured tok/s, reasoning-hybrid quirk, MCP not wired): **`docs/lfm3.md`**.

## Inkling-2-Mini swap lane (`inkling-2-mini.service` — now strata-inkling)

⚠️ **Switched from llama.cpp to Strata's own `strata-inkling` engine on 2026-11-24** (0.2.21, engine 0.1.67, HIP/gfx1201, native SQ-20 pack). Thinking Machines' Inkling 2 Mini (2026-11-20, Apache 2.0) is the one model here with a **depth wedge open upstream** — 81–122K prompts that must replace a resident context read "complete" (79K tokens in 10 s: skipped) and then never emit a token while the engine spins. Evidence, the four configurations that all wedge, and the one variable that changed it (`--chunk 512`) are in **`docs/inkling-depth-wedge-2026-11-24.md`**; upstream report **Niko1221/Strata#7096** — maintainer replied 2026-11-25; the three tests they asked for were **run 2026-11-25** and all completed (no reproduction at `--chunk 2048`, and the "190 s first chunk" reading was retracted as queue wait) — results and the reply in **`docs/inkling-7096-test-plan.md`**.

- **Fallback = the old llama.cpp run line** (still in this file's git history and in `docs/inkling.md`): UD-Q4_K_XL, `-c 131072`, `-fa on`, `-ctk/-ctv q8_0`, `-b 1024 -ub 512` (load-bearing), `--device ROCm0` — 33–36 t/s, 131K, 99.9 % reuse, never wedged.
- **Files**: SQ-20/SQ-10 + vision + drafter by `scripts/fetch-inkling-strata.sh` (size+sha pinned); the GGUF by `scripts/fetch-inkling-2-mini.sh`.
- ⚠️ **A `nixos-rebuild switch` starts `strata.service` even while a partner engine is live** — after any switch on zen3: `sudo systemctl stop strata && sudo systemctl start inkling-2-mini`.

Full details (backend A/B, prefill curve, `-ub` sweep, why Flash-Next differs): **`docs/inkling.md`**.

## opencode supervisor plugin (`users/cjdell/opencode/plugins/supervisor.ts`)

A plugin of the auto-context family that lets the **LFM3 lane police the Strata lane**: it subscribes to opencode's thinking events and intervenes on long-horizon agent runs so they finish unattended. Live since 2026-11-11.

- **Large-steps-only policy**: a thinking step under 4000 chars is not supervised at all.
- Three gates: **(1) token collapse** (unique-char-8-gram ratio < 0.01 → interrupt + steer), **(2) verbatim loop** (≥3 consecutive similar BIG steps → deterministic interrupt), **(3) premature stop** (on `session.idle`, deterministic when unambiguous, LFM3 judge when ambiguous → queued nudge). Budgets: 4 loop + 3 stop nudges/h/session.
- **Judge lanes = fleet-wide**: `http://127.0.0.1:8086` first (zen3), then `http://192.168.49.50/lfm3/v1` via nginx.
- **Judge reliability**: LFM3 JSON prompts need `max_tokens 1200` (at ≤900 it dies `finish=length` with empty `content`).

Full details (ops traps, event-type gotchas): **`docs/opencode-supervisor.md`**.

## Recallium (memory server, live on zen3-nixos)

Recallium (`recalliumai/recallium` container, rootful podman like `diamcp`) is a memory server for AI agents: MCP + web UI + Postgres. Its LLM processing runs on the **Strata engine** (no cloud).

- **UI**: `http://192.168.49.50:9001`, `/recallium/`, or `https://recallium.ai.chrisdell.info/`
- **MCP**: `http://192.168.49.50/recallium-mcp` or `https://recallium-mcp.ai.chrisdell.info/`
- **REST**: `http://127.0.0.1:8001/api/...` or `https://recallium.ai.chrisdell.info/api/...`; Postgres on `127.0.0.1:5433`
- **Chain**: container → nginx `/recallium-llm/` → **`recallium-llm-shim` on `127.0.0.1:8090`** → **Strata on `127.0.0.1:8080/v1`**. The shim adds `chat_template_kwargs.enable_thinking=false` to `/chat/completions` bodies (Recallium asks for `max_tokens=2000` and Strata's `answer_room` spends 1488 of it thinking).
- **Operational essentials**: `POST /api/memories/` always returns 500 (upstream bug — the row is still created; read it back via `GET /api/memories/{id}`); there is no API to change the LLM model (edit `llm_provider_configs` in Postgres directly, then `sudo podman restart recallium`); zombie generations (a slow/looping model leaves an orphan that blocks the single slot — last resort is `sudo systemctl restart strata`); `recallium-healthcheck` oneshot must always exit 0.

Full usage docs: **`docs/recallium.md`**.

## hass-rs shadow hub (grafton-router, shadow mode)

`crates/home-assistant-rust` (upstream `cjdell/home-assistant-rust`) is a Rust rewrite of Home Assistant core that runs **beside** the real HA container on grafton-router. It is a git submodule, consumed as the `home-assistant-rust` **`git+file`** input (`flake = false`).

- **Config** is a `linkFarm`: generated `configuration.yaml` with Mosquitto at `192.168.49.1:1883` (client id `hass-rs-shadow`) and a `.storage` symlink to `/srv/homeassistant/config/.storage`. Areas, entity/device ids and `core.restore_state` are imported read-only from the live HA install.
- **Ports**: HA-compatible API on `127.0.0.1:8126` (loopback only), dashboard on `127.0.0.1:8125`.
- **Dashboard**: `https://hass-rs.home.chrisdell.info` → nginx → `:8125`. Server-rendered (Topcoat, pinned 0.6.2), **no login**; nginx allow-lists LAN/VLAN10/WG/tailnet + the LAN /64, then `deny all`. That is the whole authentication story — do not remove the allow-list.
- **Shadow mode**: `--no-automations`; the real HA owns the automations. Buttons/sliders *do* publish to `zigbee2mqtt/<dev>/set`, so do not click them in smoke tests.

Full details: **`docs/hass-rs.md`**.

## Thread border router / Matter over Thread (grafton-router, staged 2026-11-26 — radio flashed & verified, awaiting its USB socket there)

A spare **Sonoff ZBDongle-P** (TI CC2652P10, shield "C2652P") runs as a **Thread border
router radio** for Matter devices. ⚠️ This is the **community** firmware path: Sonoff's own
flasher is Zigbee-only for the CC2652P (their OTBA guide's "Thread" entry is the newer
Dongle-PP10). RCP firmware = Koenkk `ot-ti` 2025.3.1 `CC1352P2_CC2652P_launchpad` build
(pinned sha256 in the script), flashed via `nixpkgs` `cc2538-bsl --bootloader-sonoff-usb` —
`sudo ./scripts/flash-thread-rcp.sh flash` on the box the stick is plugged into, no disassembly.

- **Service**: `hosts/grafton-router/services/otbr.nix` — official `openthread/border-router`
  image (digest-pinned) on host network, `OT_RCP_DEVICE=spinel+hdlc+uart:///dev/otbr-rcp?uart-baudrate=460800`
  (no HW flow control), infra iface `lan`, REST on loopback :8081, mesh state persists in
  `/srv/otbr/thread` (back it up; loss = recreate mesh + re-commission devices).
- **Device identity**: this stick is the **CP2102N** P revision (`10c4:ea60`) with a
  **unique serial** → udev matches the serial (`rcpSerial` in otbr.nix) and symlinks
  `/dev/otbr-rcp`; it can sit in any USB socket, and the box's other serial adapters
  (idle CH340 on 1-7, an FTDI) can never be grabbed. Swapping the physical stick ⇒ update
  `rcpSerial` (empty = service fully inert). Radio verified after flashing with
  `otbr-agent --radio-version` → `OPENTHREAD/1.4.0-Koenkk-2025.3.1; CC13XX_CC26XX`.
- **Firewall**: `forward` is `policy drop` here — the `lan ↔ wpan0` pair in
  `networking/firewall.nix` is load-bearing; otbr's own `OT_FORWARD_INGRESS` ip6tables chain
  (mesh-into-unicast filter) also shows up and is expected, not cruft.
- **Never let this unit start during activation** (proven 2026-11-27: a unit failing to
  start mid-switch aborted the switch AFTER the profile moved → autoRollback REBOOTED the
  router 5 min later). `podman-otbr` is `wantedBy=[ ]`; the lifecycle is udev
  (`TAG+="systemd"`+`ENV{SYSTEMD_WANTS}="otbr-rcp-plug.service"` on the stick's
  rule — `RUN+="systemd"` is program-exec and NixOS rejects it at build time)
  plus an `otbr-udev-nudge` oneshot (boot + first-rule-deployment). Four
  traps learned live: (1) **never** drive this from a systemd `.path` unit —
  `PathExistsGlob` re-triggers whenever the triggered unit *deactivates*, so a
  oneshot loops at script-execution speed (2757 activations/2 min measured;
  systemd.path(5) semantics, no udev/container involvement). (2) The plug unit
  guards on device `inode:ctime` vs `/run/otbr-rcp-plug.state` so repeat events
  no-op — and must never run `udevadm trigger` itself (trigger inside the unit
  its own rule starts = the same loop). (3) podman `--device` resolves symlink
  sources — the explicit `src:target` form is mandatory or the agent ENOENTs
  the radio URL. (4) `systemctl try-restart` on an inactive unit is a silent
  no-op — the plug uses plain `restart`.
- **HA**: no HAOS add-ons on this fleet — add the `otbr` integration (`http://127.0.0.1:8081`)
  → `thread` integration appears → set preferred network → commission via the existing
  matter-server (BLE hci0). Upstream caveat: one closed report of OTBR losing the CC2652P RCP
  when a device joins — the rollback is flashing any Koenkk Z-Stack coordinator hex back.

Full runbook + hashes: **`docs/thread-border-router.md`**.

## DeepSeek Harness web GUI (`dsh-web-harness`, live on zen3-nixos + grafton-router)

The forked DeepSeek Harness Web GUI, as an always-on service: `common/dsh-web-service.nix` (`services.dshWebHarness`), enabled by `hosts/zen3-nixos/dsh-harness.nix` (`192.168.49.50:3080`) and `hosts/grafton-router/dsh-harness.nix` (`192.168.49.1:3080`).

- **The bare URL is `401` by design.** `dsh web` mints a random launch token per process; that URL is the bootstrap. Get the live one with **`dsh-web-url`** (prints the LAN URL; `--local` for loopback, `--open` to open it in a desktop browser).
- **What it mints is the bookmark.** The token sets an HttpOnly, SameSite=Strict `dsh-auth-…` cookie, bound to the authority it was issued for and signed with a durable secret, so it survives restarts and rebuilds. It lives `services.dshWebHarness.cookieMaxAgeDays` (default 3650 days).
- **Don't undo the `!!js` line** in the module's cordis patch layer — a patch **replaces** the matched row's whole `config`, so the row restates `trustedHosts: !!js ctx.webRuntime.trustedHosts` verbatim.

Full details: **`docs/dsh-harness.md`**.

## meter-relay-rs (grafton-router, live)

The solar-inverter meter relay on **grafton-router** is built from the Rust crate at `crates/meter-relay-rs` in this repo. It reads the grid meter over serial Modbus RTU, re-serves those registers to the inverters, nudges them with per-inverter PIDs so grid export tracks `MR_METER_TARGET_POWER`, charges the batteries in the Octopus Go window, publishes to Home Assistant + InfluxDB, and serves a Solid.js dashboard on `:8484`.

- **The endpoint→role mapping is discovered at startup** (the ports are not stable). `MR_*_PORT`/`MR_STATS_PORT` are **hints**; at startup `src/discovery.rs` *listens* for each inverter's own meter polls and *probes* only the endpoints that stayed silent. `MR_DISCOVERY_STRICT=true` (the deployed setting) refuses to start when a required connection cannot be placed.
- **Every connection reconnects on its own** (250 ms backoff doubling to 10 s). `/api/connections` and the diagnostics page make drops visible.
- **The plant is a priority list**, not two hardcoded inverters. `MR_INVERTERS` orders it; each entry takes `MR_<ID>_*` overrides.
- **Allocation water-fills in both directions** — surplus PV the main bank's charge taper cannot absorb spills into the reserve.
- **Module**: `hosts/grafton-router/services/meter-relay.nix` is the relay's entire configuration — the plant is declared there as an attrset applied via systemd `Environment`.
- **Build**: the crate lives in this repo; the root flake builds it. No Rust toolchain on grafton-router — use `nix shell nixpkgs#cargo nixpkgs#rustc nixpkgs#pkg-config nixpkgs#stdenv.cc nixpkgs#udev.dev nixpkgs#clippy --command bash -c 'cd crates/meter-relay-rs && cargo test && cargo clippy --all-targets -- -D warnings'`.
- **Deploy**: `scripts/deploy-meter-relay.sh` does all of the below and verifies the result (`--no-rebuild` evaluates and reports only; it refuses to switch on any host but grafton-router). By hand: `git status crates/meter-relay-rs` → `git add -A crates/meter-relay-rs` (new files must be staged or Nix cannot see them) → `git commit` → `sudo nixos-rebuild switch --flake .` → `sudo nixos-confirm` → `systemctl status meter-relay && journalctl -u meter-relay -f`.

Full details (discovery, estimator, known gaps, failure modes): **`docs/meter-relay.md`**.

## Avalon (Qwen3.8-Flash-Next on the R9700 — DISABLED 2026-11-04, same day)

Avalon (github.com/freriadoc/Avalon) replaced Strata on `:8080` on 2026-11-04 — deliberately, keeping **every client URL identical**. It is a fork of llama.cpp tuned for exactly the one model this box serves (Qwen3.8-Flash-Next, 512-expert MoE), with the experts hosted in system RAM, a GPU expert cache prefilled from `moe-cache-ranking.bin`, MTP speculative decoding from a shared draft head, and fused RDNA kernels. **Rolled back to Strata on 2026-11-04** — the flip-back is the import swap in `hosts/zen3-nixos/ai/default.nix` (comment `./avalon.nix`, uncomment `./strata.nix`) **plus** restoring `gpu-mode.sh` + `sd-server.nix` to the matching era's version from git history.

Full details (flake, service, model data, rollback procedure): **`docs/avalon.md`**.

## Strata (Qwen3.8-Flash-Next on the R9700 — LIVE AGAIN since 2026-11-04)

The serving engine is **Strata** (a separate stack from llama.cpp), pinned at **0.2.13.1+main-13eedf55** (tag `628f7495` + main `13eedf55`, engine **0.1.59.1**) — reverted back to it on 2026-11-20 16:24 after the 2026-11-20 prefill stalls hit 0.2.15 and 0.2.17. Full evidence pack: **`docs/strata-prefill-stall-2026-11-20.md`**.

- **One request at a time** (`/v1/status` → `concurrency.serving: 1`): Strata's batching is available but off by default — toggled by **`strata-batch on|off|status`**. Measured on 0.2.13.1 with it ON, then switched back off: slots cost 2.34 GiB VRAM + 85 MiB×2 DFlash2 slot-drafters and ~10 GiB pinned RAM, shrinking the expert cache 24.54→21.99 GiB (−10.3 %); a *lone* stream decodes 39.2 vs 56.9 tok/s. Analysis: **`docs/strata-batching.md`**.
- **The whole card is a lease, not an allocation**: `gpu-mode sd|game` **stops `strata.service` outright** — do not "restart it for good measure" while testing SD or gaming.
- **DFlash2 is LIVE as the drafter** (`"drafting": "dflash2"` in `strata.nix`'s `configFile`): 0.2.10 made it the `auto` pick for Qwen3.8-Flash-Next on CUDA/HIP/Metal/SYCL. Since 0.2.12 `auto` now picks MTP on gfx1201 (the DFlash2 prompt stall is open), so the explicit `"drafting": "dflash2"` is what we run. `"drafting": "mtp"` remains the one-line revert.
- **One pack live, two kept as schema**: `config.ai.strataModel` = `"ud-iq4-xs-v31"` (Unsloth's Dynamic v3.1 re-cut of UD-IQ4_XS, 93.7 GB / 4 shards, live since 2026-11-05 15:20). The old three-shard UD-IQ4_XS and the GSQ-RCO IQ3_S GGUFs have been deleted.
- **Second family, selectable since 2026-11-18**: `models.qwen36-ud-q4-k-xl` — Qwen3.6-35B-A3B (35B MoE / 3B active / 256 experts / top-8, arch `qwen35moe`). An own-path engine: reads ONE GGUF in place, no iq_pack, no expert profile, no PLE shard, no `--resident-budget-gib`. Run line = `--native <gguf> --max-context 131072 --prefill auto --mtp 2`. **On the pinned 0.1.59.1, 256K cannot be fully VRAM-resident at UD-Q4_K_XL** (weights+KV = 32.83 GiB before buffers; ceiling ≈145–167K, and `--max-context 262144` starts *silently in hybrid mode* — upstream's fit rule only predicts starting) — quant options that do fit, the memory model, and the safe test: **`docs/qwen36-256k-vram.md`**.
- **Qwen3.6 q36 lanes on engine 0.1.67, MEASURED 2026-11-26**: engine 0.1.6x has KV widths on this path (`--kv fp32|fp16|fp8|fp4`; at 262,144 that is 11.56 -> **1.65 GiB** fp4), so the existing `UD-Q4_K_XL` file does 256K **fully resident** - measured, not predicted: `every routed expert in VRAM (18.75 GiB)`, 2,567 MiB free, decode **165 tok/s cold / 48.4 at 138K fill / 24.9 at 258K fill**. Three lanes on the v0.2.21 build (`hosts/zen3-nixos/ai/strata-q36-package.nix`, target `strata-q36` only; `nix build .#strata-q36`) while Flash-Next stays on 0.1.59.1: `qwen36-256k-fp4` (8097, the 256K default), `qwen36-256k-fp8` (8096, 19.6 at 253K - slower at depth, better KL), `qwen36-128k-fp8` (8099, 131072 + fp8 cache). **The 128K lane is the big result**: narrowing the cache there is worth **3.25x at 60K fill and 4.15x at 122K** (75.4 / 49.0 tok/s against fp32 KV's 23.2 / 11.8 on the same engine), because the depth collapse is the dense attention read - NOT the K-quant loader bug (#3925, #5595) this file previously suspected: on 0.1.67 with fp32 KV the 60K-fill decode is 23.2 against the pin's ~22.5, i.e. unchanged. What 0.1.67 does add is MTP, which was **dead on the pin** (`drafts accepted 0 of 0` on every request in `/var/lib/strata-qwen36-ud-q4-k-xl/strata.log`) and is worth +63 % cold; `--mtp 2` beats 0 and 3. Measurement harness: `scripts/qwen36-256k-check.sh` (`status` / `go fp4|fp8|128kfp8` / `single` / `restore`), full tables in **`docs/qwen36-256k-vram.md`**.
- **Third Flash-Next pack, selectable since 2026-11-22**: `models.coder-iq1m` — Qwen3.8-Flash-Next Coder (IQ1_M, 58.4 GB in two shards). DFlash2 must NOT be configured for it (`dflash2 = false`).
- **Model choice via the API — `strata-swap`, live on `:8080` since 2026-11-18**: the shim owns `127.0.0.1:8080`; the engines moved behind it (primary `strata.service` → `:8091`; one unit per selectable model → `:8092+`). A request whose `model` exactly names a non-live engine triggers a SWAP — wait for the live engine's `activity.in_flight` to drain → stop live unit → wait for free VRAM → `systemctl start strata-<key>` → poll `/v1/status` `loaded:true` → forward the buffered request. Name-blind traffic follows the live engine.
- **The engine does not run on nixpkgs' ROCm — it runs on a store-built ROCm 10.0.0** (`hosts/zen3-nixos/ai/rocm10-runtime.nix`). Do not "simplify" it back to `pkgs.rocmPackages`.
- **Verify the running engine, don't assume**: `systemctl show strata -p ExecStart` and `readlink /proc/$(pgrep -f '[b]in/strata --serve')/exe` must show the store path from the latest build.
- **Deploy**: edit `strata-package.nix`, `nix build .#strata --no-link`, then `sudo nixos-rebuild switch --flake .` (zen3-nixos has autoRollback commented out — no `nixos-confirm`).

Full details (0.1.43/0.1.44/0.2.12 answer-changing defaults, the #879 audit, the fp16-overflow clamps, the hang-watchdog class, the 0.2.17 port notes, the swap shim contract): **`docs/strata.md`**.

## grafton-router has TWO tailscale connections (and only one is monitored)

`tailscale status` on grafton-router shows the **grafton** tailnet (our headscale at `tailscale.home.chrisdell.info`, `100.64.0.0/24`, magicDNS `grafton.tailscale`). The **leighhack** tailnet (theirs, `tailscale.leighhack.org`, `10.3.0.0/16`, `int.leighhack.org`) is a *different* connection: it runs inside the `grafton-hackspace-client` microVM and is reached via a hand-written `ip route 10.3.0.0/16 via 192.168.49.15`. **A perfectly healthy `tailscale status` says nothing about leighhack.** When leighhack is down, what actually breaks is DNS: `adguard.nix` forwards `[/int.leighhack.org/]10.3.1.1:53`, so the symptom is "a page won't load", not "a VPN is down".

Full write-up: **`docs/leighhack-tailscale.md`**. Diagnose with `sudo ~/nixos-config/scripts/check-hackspace-tailscale.sh`.

## Known gotchas on this host

- **`/nix/store` is bind-mounted read-only** for everything except `nix-daemon` — delete paths with `nix store delete <path>`, not `rm -rf`.
- **GPU pinning**: the mesa device-select layer reorders Vulkan devices so the boot-VGA (console) GPU comes first when `MESA_VK_DEVICE_SELECT` is unset. The R9700 drives no screens — the console lives on the iGPU — so `-dev Vulkan0` used to silently mean the Vega. Fix: the r9700 router wrapper sets `XDG_DATA_DIRS=/run/opengl-driver/share` and `MESA_VK_DEVICE_SELECT=1002:7551!` (trailing `!` exposes only that device).
- **CPU swap 2026-10-08 (5700G → 5950X): the PCIe bus re-enumerated, so BDFs and render minors are NOT stable.** Match GPUs by PCI id/UUID, never a BDF or a renderD minor.
- **The r9700 HIP fork is gone** (all llama.cpp forks removed 2026-09-26). The router runs upstream `llama-cpp` (Vulkan) only.
- **`sudo nginx -T`/`-t` is misleading *and* has a side effect** — it reads the package's stock `conf/nginx.conf` unless you pass the generated one, and a root-run nginx chowns every `*_temp_path` dir under `/var/cache/nginx` to `nobody` (65534), mode 0700, which locks the worker out. Recover with `sudo find /var/cache/nginx -mindepth 1 -maxdepth 1 -exec chown nginx:nginx {} +`.
- **The NixOS nginx unit runs `daemon off`** under systemd (foreground). Standalone nginx tests need patched `pid`/`error_log`/`access_log` paths, ports, and `setsid`/`nohup` to background.
- **The `llama-log-viewer` systemd service runs as root** because `/home/cjdell` is `700`.
- **`python3` is not on PATH**; use `nix shell nixpkgs#python3 --command …`.
- **Rust**: `cargo 1.95` is on PATH but `rustc` is broken; use `rustup run stable cargo build --release` with the gcc wrapper from the system if you must build the app outside Nix. Prefer `nixos-rebuild`.
- **The nginx `/logs` route strips its prefix** with an explicit rewrite (`rewrite ^/logs/?(.*)$ /$1 break;` + `proxy_pass http://127.0.0.1:8083;`).
- **Partition layout / NVMe naming**: `/` is on the WD Black p3 (250G, at the *end* of the disk), `/home` on p5 (~681G), `/boot` the ESP (548M). There are two NVMe drives and their kernel names (`nvme0n1`/`nvme1n1`) **swap between boots** — always resolve by fs UUID, never by device path.
- **`resize-once.nix` is a disabled one-shot initrd resize** (completed 2026-08-14). Import commented out in `default.nix`; full write-up in `docs/resize-once.md`.
- **The ESP fills up** as generations accumulate (each initrd ~65MB); prune the system profile to keep the 548M ESP bootable.

Full details: **`docs/zen3-gotchas.md`**.

## patchelf 0.19.2 breaks NVIDIA and CUDA binaries (current pin)

The pinned nixpkgs ships **patchelf 0.19.2**, which mangles NVIDIA's prebuilt binaries (NixOS/patchelf#674, NixOS/nixpkgs#576412). Two workarounds are carried locally — delete both once nixpkgs ships the patchelf fix.

- **`nvidia-smi` (and `nvidia-cuda-mps-*`, `nvidia-debugdump`, `nvidia-powerd`) segfaults.** Fix: re-patch from the pristine copies the builder keeps in `$bin/origBin/`, **rpath first, interpreter second** — carried in `hosts/asus-i7-6700-nixos/hardware-configuration.nix` and `hosts/kabylakeitx-nixos/hardware-configuration.nix`.
- **The merged CUDA set cannot be built at all** — `cudaPackages.cudatoolkit` trips the same bug inside `autoAddDriverRunpath`. `common/sunshine-nvidia.nix` therefore no longer puts `cudatoolkit` in `environment.systemPackages`.

Full details: **`docs/patchelf.md`**.

## Web fetching (context safety)

`fetch` returns the **entire page** into the conversation with no size cap — a single large fetch can overflow the model's context window. Follow this order:

1. `fetch` is fine only for small, known endpoints (API/JSON, short pages).
2. For unknown or potentially large pages, download with the terminal and inspect surgically: `curl -sL <url> -o /tmp/page.html` → then `grep` or `read_file` for just the parts you need.
3. If content must appear inline, bound it: `curl -sL <url> | head -c 20000`.
4. Never return multi-megabyte content into the conversation.

## gpu-probe: the selective GPU stress ladder (`scripts/gpu-probe/`, `nix build .#gpu-probe`)

The tool for "the card dies under X but is flawless in Y" — on this fleet that has meant the Z240 heaters. Benchmarks that validate nothing are what make these faults look impossible (FurMark = a GL loop: never checks its output, never touches the CUDA compute engine), so the ladder varies **one axis per step** and lets the death name the axis.

- **No CUDA toolkit, no compiler**: the compute kernels are hand-written PTX that the *driver* JIT'es through `ctypes`, and the OpenCL programs are compiled at runtime by the vendor ICD — so it runs on any host, and the CUDA-only axes self-skip (`TOOLING-SKIP`) on the AMD boxes.
- **A kill is not recoverable without a reboot — and the ladder will not reboot your box.** It records the verdict, advances the step counter and **HALTS**; you reboot and re-run, and it resumes at the next step.
- It **re-asserts the operating point every boot and verifies it held** (`--power-limit`, `--link gen3|gen1`).
- Telemetry: `runs/NN-step.csv` every 2 s plus `NN-step.csv.transitions`. ⚠️ **Do NOT read `link-transitions` as a fault indicator** — a link that parks at 2.5 GT/s while the GPU is idle and climbs to 8.0 GT/s when work arrives is *correct* behaviour. The signal is **`under-load-drops`** = a downgrade **while utilization > 80 %**.
- Verdicts: `PASS` / `DIED` / `DIED-CARD-GONE` / `TIMEOUT-STALL` / `TIMEOUT-SLOW` / `SKIP-TOOL` / `TOOLING-SKIP` / `DRIVER-ERR`. `rc=124` alone is a budget, never evidence.

Full details (step tables, `gpu-probe-traditional`, `gpu-probe-envtest`, `gpu-probe-fahcore-repro`): **`scripts/gpu-probe/README.md`**.

## Workflow conventions

- **Prefer helper scripts over inline one-liners** for repeated/complex operations (HA API calls, multi-step deploys, TFTP testing, …). Keep them in `scripts/` (committed) or `/tmp/` (scratch), make them idempotent, and give every network call a `timeout`.
- **Set timeouts on everything that talks to the network** (`timeout N cmd`); bare `ssh`/`curl`/`ping` to a flaky or dead host will stall the session. Never `pgrep -f`/`pkill -f` with a pattern that matches your own shell's command line.
- **Poll for long-running work with a bounded loop, never one long `sleep`.** Run the job in the background with output to a log, then loop a short sleep with a status line each iteration.
- **Watchers must be kill-proof by construction: log marker, not `systemctl`.** Remote-state polling (`ssh host 'systemctl is-active X'`) is the unreliable half — under heavy NFS/disk load `systemctl` wedges on its dbus round-trip and the ssh probe times out, while plain file reads on the same host keep working. Key completion on the job's own log, written by the wrapper script itself, and `grep` for it via ssh.
- **Reaping a wedged background shell when the UI kill fails**: find the group and signal it — `ps -eo pid,pgid,etime,args | grep "[u]nique-watch-word"`, then `kill -KILL -<PGID>`.
- **Never pipe a whole capture file through a byte-level tool.** Read a bounded window instead — `dd bs=1M count=2 iflag=skip_bytes skip=<offset> if=FILE | od -tx1` — and ask first whether the check is even needed.
- Do not run heavy builds unless the task requires it; the user applies Nix config themselves when they prefer.
- If you DO apply a config (with permission), always finish with `sudo nixos-confirm` on autoRollback hosts.
- The repo often has uncommitted/staged changes plus untracked scratch files. Leave them alone unless the task is about them.

Full details: **`docs/workflow-conventions.md`**.
