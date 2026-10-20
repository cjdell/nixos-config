# AGENTS.md

Guidance for AI coding agents working in this repository. Read this before making changes.

## Step 0: identify the host you are on — before anything else

**Do not assume you are on zen3-nixos.** This repo is checked out on several
machines — verified 2026-10-08: `~/nixos-config` exists on **zen3-nixos,
grafton-router, N100-NAS, GEN8-NAS and N40L-NAS** (plus alderlake-thinkpad and
the MacBookAir, where the rebuild is `just switch`) — and the flake
evaluates/builds *every* host from *any* of them. Start by asking where you are:

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
  `llama-swap`, `sd-gate`, Recallium, diamcp, llama-log-viewer),
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

A NixOS flake-based configuration managing many hosts (NAS boxes, ThinkPads, a Zen 3 GPU
workstation, etc.). Key layout:

| Path | Purpose |
| --- | --- |
| `flake.nix` | Flake definition; builds every `hosts/<name>` dir as a NixOS config |
| `hosts/` | Per-host configuration. **Directory name == host name** (e.g. `zen3-nixos`) |
| `common/` | Shared modules (`system.nix`, `desktop.nix`, `sops.nix`, …) |
| `users/` | User configs (home-manager) |
| `machines/` | Legacy configs for older machines (referenced from `flake.nix`) |
| `crates/` | Every Rust crate in this repo (`llama-log-viewer`, `sd-gate`, `gpu-panel`, `ollama-bridge`, `meter-relay-rs`), built by the root flake (see below) |
| `llama-logs/` | Live `llama-server --log-prompts-dir` output consumed by the viewer |
| `docs/recallium.md` | How to use the Recallium memory server (APIs, MCP, examples) |
| `docs/klipper-3d-printer.md` | 3d-printer-server / Klipper (Smoothieboard LPC1768): boot-race fix, `klipper-firmware-update` + SD-flash runbook, and the **open** thermistor/ADC fault |
| `docs/gtt-vram.md` | GTT-default/VRAM-cache research: `GGML_VK_ALLOW_SYSMEM_FALLBACK`, why there's no weight cache in llama.cpp, and why GTT never auto-unspills |
| `docs/zen3-random-crashes.md` | **OPEN** investigation into zen3-nixos' random hard resets (watchdog-reaped hangs, not panics; memory/IMC hypothesis; `[S]`=CPU_OUT_OF_SPEC) + the `scripts/stress-monitor.sh` soak harness — sequel to `docs/kernel-rcu-wedge.md` |
| `docs/billion-context.md` | The `billion-context` context-compression proxy (ACP `compress` tools + fold nudges): config location/merge order, why folds fired at ~50 % of a 256K window (`nudgeGrowthTokens` + `outputHeadroomMaxPct`), the 2026-09-30 tuning, the exact nudge-gate formulas, and how to health-check it (`bili doctor`, `/__bili/*` on the **pi lane port 18789**, not 18787) |
| `docs/strata-hang.md` | Strata's `no progress for 60 s` watchdog aborts (upstream #29) → 32 GB core dumps → amdgpu MES teardown failure + MODE1 GPU reset: why the cores are useless, the journal line that names the stall, and the `HSA_USERPTR_FOR_PAGED_MEM=0` candidate fix (#750 = two R9700s on ROCm 7.2) |
| `docs/strata-batching.md` | Strata **batching / concurrent sessions** (`"parallel"` → `--batch N`, `--batch-mtp`, `--batch-groups`): why zen3-nixos stays at `concurrency.serving: 1` — slots cost 0.56 GiB of expert-cache VRAM each (232 MiB free) and carry **no MTP drafts** by default, the RTX 5070 table (2 concurrent = −15 % aggregate, TTFT 4.1 s → 0.9 s) vs the `--batch-mtp` +31–39 % single-card claim and the 2× R9700 −21.9 % counter-example, the #1603 risk the single-slot setup avoids, and how to enable + verify it |
| `docs/strata-expert-helper.md` | Options for a **second GPU as a Strata expert helper** on zen3-nixos (from #879): the three walls (mixed-vendor unsupported, ROCm arch coverage, and the board's second slot training at **Gen1 x2 = 0.5 GB/s**), candidate cards (RX 580 unusable / RTX 2060 needs a cross-vendor patch / RX 5600 gfx1010 clean but link-bound), the #1184 +10–18 % reference numbers, and why the PCIe link is the dealbreaker |
| `docs/leighhack-tailscale.md` | The **second** tailscale net on grafton-router (the hackspace's, `10.3.0.0/16`, via the `grafton-hackspace-client` microVM): why `tailscale status` being healthy proves nothing about it, the diskless-VM + single-use-pre-auth-key root cause of the 2026-10 outage, `scripts/check-hackspace-tailscale.sh`, and the QMP trick for a console in a VM with no password |
| `secrets/` | sops-encrypted secrets |
| `scripts/` | Install/PXE helper scripts |

Formatting: `./format.sh` runs `nixfmt` over all `.nix` files.

## The servers on the network (who runs what)

All in `hosts/<name>` (directory name == host name == flake attribute), on the
`192.168.49.0/24` LAN with domain `grafton.lan`; tailnet names are
`<host>.grafton.tailscale`. Static leases for everything below are in
`hosts/grafton-router/networking/dns.nix` — that file is the network map. The
"what it runs" column is the headline set, not exhaustive.

| Host | LAN IP | Role | What it actually runs | Deploy notes |
| --- | --- | --- | --- | --- |
| **grafton-router** | `.1` (`2a02:8010:6680:49::1`) | Edge router **and** the main homelab app host | PPPoE WAN (`pppoe-zen`), `lan` bridge + VLAN10, nftables, dnsmasq DHCP+DNS, AdGuard, WireGuard `10.47.0.0/16`, headscale + Tailscale, **kanidm** IdP (`kanidm.home.chrisdell.info`), nginx public edge `*.home.chrisdell.info` (ACME DNS-01 Route 53 + route53 dynamic DNS) proxying to itself *and* to N100-NAS (`grafana…`→`:3000`, `filebrowser…`→`:8002`), Home Assistant + InfluxDB + Mosquitto + zigbee2mqtt, Frigate (+`frigate-whisper`/`frigate-monitor`), Jellyfin, Immich, qBittorrent, Ghost, 2fauth, Beszel, Postgres, **meter-relay** (`:8484`), container-ui, TFTP/iPXE netboot, a microVM host (`grafton-hackspace-client`, `.15`), dsh-harness `:3080` | **autoRollback ON** → `sudo nixos-confirm`. 15 GiB RAM + 8 GiB `/swapfile`. No Rust toolchain. Config is `hosts/grafton-router/` (imports its own flake inputs). |
| **zen3-nixos** | `.50` (`…:49::50`) | AI workstation + primary build box | Strata `:8080` (R9700 32 GB; llama-swap `:8081` is **disabled** — see the Strata section), sd-gate + SDXL, Recallium (its LLM = Strata via `/recallium-llm`), diamcp, llama-log-viewer, gpu-panel, nginx `*.ai.chrisdell.info`, Pi 5 netboot (TFTP `/etc/tftp`, NFS store snapshot `/exports/nix-store`) | autoRollback **commented out** → no `nixos-confirm`. zram swap. Dispatches aarch64 builds to the MacBookAir; is itself the builder for alderlake-thinkpad and macbook-pro-2009. |
| **N100-NAS** | `.22` | Media/app NAS (ZFS pool `samsung-4tb`: `ds-media`, `ds-photos`) | Jellyfin, Immich (podman: server/ml/redis/postgres), qBittorrent, Postgres + postgresqlBackup, filebrowser, Grafana `:3000` (kanidm OIDC, `grafana.home.chrisdell.info`), container-ui `:8091`, Samba + NFS, sanoid + syncoid → N40L-NAS and dbthr33, Scrutiny, Prometheus exporters, Tailscale | **autoRollback ON** → `sudo nixos-confirm`. Repo checkout lives here too. `common/folding-at-home.nix` (the linuxserver container) is imported — it was crash-looping on every host over an unqualified image name, fixed 2026-10-20, so it will start CPU-folding on the next switch of every host that imports it. |
| **GEN8-NAS** | `.23` | Bulk file + snapshot host (ZFS `sas-24tb`: `ds-public`, `ds-cjdell`, `ds-backup`) | Samba + NFS shares, sanoid snapshots, syncoid → N40L-NAS, `backup-host` receiver (`backup` user, `/var/lib/backup`), Scrutiny, Prometheus exporters, Tailscale, `lsiutil`/`sasutils` (HBA) | no autoRollback. ZFS via disko. |
| **N40L-NAS** | `.21` (`…:49::21`) | The backup **target** (ZFS `sas-16tb`) | Receives the GEN8 + N100 syncoid streams under `sas-16tb/ds-external-backups/…`, holds dbthr33's `ds-frigate-archive`, UniFi controller container, `zfs-status`, Scrutiny, Tailscale | `nfs.nix`, `samba.nix` and `backup.nix` exist in the directory but are **not imported** by `default.nix` — no shares and no offsite push from this box. no autoRollback. |
| **zen1-nixos** | `.51` | folding@home **space heater** (Ryzen 1800X 16t + RX 5700 XT) | Native FAH v8 client `fah-client.service` folding on all 16 threads + the GPU (donor `cjdell`, team 236565, linked to the FAH account). `common/folding-at-home-native.nix` + `common/fah-packages.nix`: nixpkgs has neither the FAH client nor a ROCm OpenCL ICD any more, so both are fetched from upstream binaries (client deb from foldingathome.org; the ROCm **6.4.3** OpenCL runtime from repo.radeon.com — the last release with OpenCL, and what the FAH AMD-GPU guide documents). Gotchas: a fresh v8 client starts **paused with GPUs disabled** (the `fah-client-configure` oneshot sends the websocket `config`/`fold` commands); the OpenMM core needs `LD_PRELOAD` of the distro libstdc++ (Navi 10+ bug, see the module comment); Web Control `http://192.168.49.51:7396/`; state in `/var/lib/fah-client` (DB + cores + `log.txt`). no autoRollback. |
| **3d-printer-server** | `.60` | Klipper 3-D-print server | prind stack as three rootful podman units (`podman-klipper/-moonraker/-mainsail`), Mainsail on nginx `:80`, `klipper-firmware-update` | no autoRollback; no GitHub creds (deploy via `git bundle`); read `docs/klipper-3d-printer.md` first. |
| **pi5** | `.92` | aarch64 netboot node (Raspberry Pi 5, no SD) — **currently off**: netboot imports commented out of `hosts/zen3-nixos/default.nix` since `dc54f4a`, no answer at `.92` | NixOS on a tmpfs root with its store served by zen3 over NFS; its config lives in the `gc-rust-node` repo, **not** this flake | Deploy = `nixos-rebuild switch` on zen3 + power-cycle (`scripts/pi5-powercycle.sh`); host keys regenerate every boot. |

Load-bearing hosts **not** in this flake: **dbthr33-server** (offsite backup
target — `backup@10.47.35.20:dbthr33/ds-external-backups/grafton` from N100-NAS;
its `2a0a:ef40:241::/48` is a trusted network in
`hosts/grafton-router/networking/constants.nix`), **inverter-pi** `.30` (the
`ser2net` Modbus-RTU bridge that `meter-relay-rs` discovers its connections
through), zigbee `.31`, jk-bms-can `.32`/`.33`, the OpenWrt APs `.2`/`.3`, and
the **MacBookAir-NixOS** aarch64 build machine — pinned to **`192.168.49.69`** by
MAC `00:0e:c6:8e:b3:ff` (wired `enu1`) in `hosts/grafton-router/networking/dns.nix`,
and `nix.buildMachines` in `hosts/zen3-nixos/default.nix` points at
`cjdell@192.168.49.69`. (Before 2026-10-08 the reservation named MAC
`18:3e:ef:c6:1c:2f`, which never matched, so the box took a dynamic `.191` — if
you see it at `.191` the lease change has not been deployed / renewed yet.)

Clients, not servers: `alderlake-thinkpad`, `rocketlakelatitude`, and the legacy
`machines/*` configs.

## Deploying an update to a host that cannot build it (NAS boxes, router)

Since 2026-10-17 every host in this flake uses zen3-nixos as a remote Nix
builder (see *Building and deploying*), so `nixos-rebuild switch --flake .`
run **on** a NAS/router dispatches its builds to zen3 and the closure-streaming
procedure below is no longer the only option — it remains useful when the
target cannot reach zen3, or when you want to guarantee the exact toplevel you
built here.

Applied 2026-10-09 to bring N100-NAS / GEN8-NAS / N40L-NAS from `26.05.20260910`
/ `26.05.20260829` onto the flake pin `26.11.20261006.151fa4e`:

- **SSH to the NAS hosts:** `cjdell` with key `~/.ssh/id_ed25519_ps` (passwordless
  sudo). The default `id_ed25519` is *not* authorized there. None of the three has
  GitHub credentials of its own (`git pull` on GEN8-NAS fails with "Please make
  sure you have the correct access rights"), so update their checkouts with **agent
  forwarding**: `ssh -A -i ~/.ssh/id_ed25519_ps cjdell@<nas> "cd nixos-config && git
  pull --ff-only"` — zen3's agent holds the GitHub key and GitHub authenticates as
  `cjdell` through it.
- **`nix copy --to ssh://cjdell@nas` fails** — `cjdell` is not a trusted user on
  any NAS (`trusted-users = root backup`). Instead build the toplevel on zen3 and
  stream the closure *delta* into the NAS store as root:
  `nix-store -qR <toplevel>` (zen3) vs `nix-store -qR /run/current-system` (NAS),
  `comm -23` the two lists, then
  `nix-store --export $(cat delta) | zstd -T2 -3 | ssh cjdell@nas 'zstd -d -q | sudo -n nix-store --import'`
  (~6 GB per host, a few minutes on the LAN), then on the NAS
  `sudo nix-env -p /nix/var/nix/profiles/system --set <toplevel>` and
  `sudo <toplevel>/bin/switch-to-configuration switch`. This skips flake
  evaluation on the target entirely and guarantees the toplevel you built is the
  one that runs. `nixos-confirm` afterwards on **N100-NAS** only.
- **A kernel bump means the ZFS module only loads on the next boot** (pools keep
  running on the loaded module; ZFS userland was unchanged at 2.4.4, so nothing
  complains). Reboot each ZFS host to actually move onto the new kernel.
- **grafton-router cannot be *evaluated* on zen3 at all**: `frigate-monitor` is a
  `path:/home/cjdell/Projects/frigate-monitor` flake input (flake.nix:37) that
  exists only on the router, so evaluating `.#grafton-router` elsewhere dies with
  `path "…/frigate-monitor" does not exist`. Rebuild it on the router — which is
  separate from using zen3 as its *builder*: evaluation happens on the router and
  only the derivations (with their path-input sources) go over ssh-ng. nixpkgs
  paths (incl. kanidm) also substitute from cache.nixos.org, so a switch there
  takes minutes even with 15 GiB RAM.
- **kanidm is now `pkgs.kanidm_1_11.withSecretProvisioning` (1.11.2, domain level
  15)** — `hosts/grafton-router/services/kanidm.nix:9`; the 1.10.5 EOL permit is
  gone from `flake.nix`. Kanidm only migrates **one minor version at a time**, so
  the next bump must be 1.11 → 1.12. Procedure that worked: tar `/var/lib/kanidm`
  with the service stopped (344 KB — copy it off-host), then run
  `kanidmd domain upgrade-check -c <server.toml>` **while the old server is
  running** (it talks to the live `/run/kanidmd/sock`; with the server stopped it
  just errors `Unable to connect to socket path`), then `nixos-rebuild switch` —
  the new server logs `migrate_domain_1_10_to_1_11` + `Domain level has been
  raised to 15` by itself. Verify with the OIDC discovery endpoint
  (`/oauth2/openid/grafana/.well-known/openid-configuration`) and
  `ldapwhoami -H ldaps://kanidm.home.chrisdell.info:8998 -x` (must use the real
  hostname — the cert will not match `127.0.0.1`).

## Critical: auto-rollback + `nixos-confirm` (READ THIS FIRST)

`system.autoRollback.enable = true` is set on **N100-NAS**
(`hosts/N100-NAS/default.nix`) and **grafton-router**
(`hosts/grafton-router/configuration.nix`). It is currently **commented out
(disabled) on zen3-nixos** (`hosts/zen3-nixos/default.nix` — no
`auto-rollback.*` units on this live system; re-enable the line to bring the
guard back). The module comes from the `nixos-utils` flake input
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
sudo nixos-rebuild boot   --flake .
sudo nixos-rebuild switch --flake .
```

- **`--impure` is no longer needed.** It was only ever required by two
  impure reads, both now removed: the `deepseek-harness` fork's flake vendored
  `node_modules` from an absolute local path (it now uses `fetchPnpmDeps`
  purely), and `hosts/N100-NAS/container-ui.nix` used
  `builtins.currentSystem` (now `pkgs.stdenv.hostPlatform.system`). The flake
  evaluates in pure mode — don't reintroduce `--impure` unless a genuinely
  impure read comes back.
- **Deploy locally when you're already on the target host:** check `hostname`
  first — if it matches the target host name (the `hosts/<name>` directory,
  e.g. `N100-NAS`), the flake is checked out on this machine, so run the
  rebuild here. Do not assume the repo lives only on zen3-nixos (*Step 0* above
  lists the hosts that carry a checkout, and the server roles table shows what
  each one runs).
- **zen3-nixos (192.168.49.50) is the fleet's build server for every machine
  in this flake**: `common/build-client.nix` (imported via `common/system.nix`
  by all hosts and directly by grafton-router) sets `nix.distributedBuilds` +
  one ssh-ng `nix.buildMachines` entry (root@zen3, 16 jobs, `speedFactor 4`)
  and keeps `nix.settings.max-jobs = mkDefault 1` — **one local build slot as
  a fallback**: when zen3 is unreachable nix marks it unavailable and builds
  locally instead of failing. Raise the fallback with `--max-jobs N` (root is
  a trusted user); passing it when zen3 is up is harmless but pointless.
  The module self-disables on zen3, which builds locally (`max-jobs = 16`)
  and dispatches aarch64-linux to the MacBookAir via its own entry.
  **`publicHostKey` is the bare Base64 key body**, not
  `ssh-ed25519 AAAAC3…`: Nix 2.34's machine-spec parser splits on the space,
  Base64-decodes the empty remainder, and fails every build with
  `invalid character in Base64 string: ''` (then `unexpected EOF reading a
  line` from the build hook). `common/build-client.nix` keeps the prefixed
  form only for the `programs.ssh.knownHosts` entry, where ssh(1) needs it.
- **Onboarding a build client**: on the client
  `sudo ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N ''`, add the printed
  public key to `users.users.root.openssh.authorizedKeys.keys` in
  `hosts/zen3-nixos/default.nix`, rebuild zen3, then rebuild the client. A
  client whose key is not authorized silently falls back to local builds —
  that's the symptom, not a bug in the module. Authorized 2026-10-17:
  alderlake-thinkpad, macbook-pro-2009, grafton-router, N100/GEN8/N40L-NAS;
  still outstanding: rocketlakelatitude, 3d-printer-server, legacy
  `machines/*` (offline when the keys were collected).
- Always follow with `sudo nixos-confirm` on hosts that enable autoRollback
  (see above).
- **Local `path:` flake inputs freeze at the `narHash` in `flake.lock`.** The
  repo consumes several checkouts that live outside it by path
  (`frigate-monitor`, `frigate-whisper`, the `llama.cpp` forks, …). Editing such
  a checkout changes *nothing* until `nix flake update <name>`
  (the old `nix flake lock --update-input <name>`, now deprecated) rewrites that
  lock entry — a plain `nixos-rebuild switch` then redeploys the previous build
  without any warning. (The Rust crates now live under `crates/` and are built
  from this repo — no path input, no re-lock.)
  **A `path:` input also copies the WHOLE directory into the store — `target/`
  and `.git` included — and its `lastModified` therefore follows build
  artifacts, not your commits.** `gc-rust-node` cost 4.8 GB per re-lock and left
  four copies in zen3's store (33 GB; the largest was 18.5 GB, all but 1 MB of
  it `target/`); it is `git+file://` since 38c9a7c for exactly that reason, as
  `home-assistant-rust` already was. Prefer `git+file://` for any local input
  with a build tree in it, and `du -sh` the directory before adding a `path:`
  one. (`frigate-monitor`/`frigate-whisper` are the same shape — worth checking
  on the router, where they live.)
  In a flake's *own* checkout Nix reads the git tree instead, so a new file must
  be at least staged (`git add`) or it is invisible to the build (both failure
  modes, with the exact symptoms, are written up under "meter-relay-rs"). A
  *dirty* working tree is still only the tracked tree: verified on nix 2.34.8,
  the dirty-checkout copy contains git-tracked files alone, so `--flake .` costs
  this repo's 5.5 MB of source and not the 18 GB of `target/` + `llama-logs/`
  lying next to it.
- Avoid running `nix build`/`nixos-rebuild` for heavy jobs unless the task
  calls for it; the user often deploys manually.
- **`hosts/grafton-router/secrets/` looks ignored but is tracked.** The root
  `.gitignore`'s `secrets/` has no leading slash, so it matches at *any* depth —
  yet `hosts/grafton-router/secrets/secrets.yaml` is in HEAD, and ignore rules
  do not apply to tracked files. The trap is that `git add` on it prints
  "The following paths are ignored … use -f" **and exits 1**, while quietly
  staging it correctly: in a `git add … && git commit` chain the commit never
  runs and it looks like the add failed. Check `git status` rather than trusting
  the exit code, and use `git add -f` for a genuinely *new* file under there
  (sops needs it in the flake source).

## The live target host: `zen3-nixos`

The repo lives here (`192.168.49.50`) as on other hosts (e.g. N100-NAS) — check
`hostname` to see which machine you're on. It runs:

- **llama-server** via `llama-swap` on `127.0.0.1:8081` (model serving). ONE
  llama.cpp router instance, on the R9700 (see `hosts/zen3-nixos/ai/llama-swap.nix`).
  **Upstream `llama.cpp` only** — the `llama-cpp` flake input
  (`github:ggml-org/llama.cpp`), built as `llama-cpp-vulkan`. The local forks
  (`llama-cpp-mtp`, `llama-cpp-rdna`, `llama-cpp-uma`) were removed from
  flake.nix on **2026-09-26**, together with the `vega` and `rx580` routers and
  the llama-swap `matrix` that kept all three co-resident: upstream master has
  `--spec-type draft-mtp`, and the fork's only unique feature (the qwen4exp
  draft head) needs a ~79 GB model that cannot fit a 32 GiB card at all. The
  Vega iGPU and RX 580 were dropped as too slow / too little VRAM to be useful.
  The single router is pinned to the physical GPU via `MESA_VK_DEVICE_SELECT=`
  `1002:7551!` (Radeon R9700 32 GB) with a trailing `!` (exposes only that
  device, so it is always `Vulkan0`) and runs with `--models-max 1` (one model
  resident), **`--parallel 1`** (one slot: concurrent requests queue instead of
  halving each other's speed) and `-cram 32768` (32 GiB idle/other KV prompt
  cache in RAM) + `--cache-reuse 256` (KV-shift reuse) + `-ctk/-ctv q8_0`
  (quantized KV) + `--models-preset` (per-model `draft-mtp` speculation).
  ⚠️ **The `-cram` cache can OOM the box — see the RAM bullet below.**
- **RAM: the `-cram` prompt cache has OOM'd this box.** The r9700's RAM cache
  grows to its cap as anon RSS under sustained use (the 450 KB per-call prompts
  in `llama-logs/`). Without swap the kernel has nothing to reclaim once the
  cache is full, and a second concurrent model load (or any big allocation)
  triggers a **global OOM that kills llama-server** — happened 4× in 5 days
  (Aug 24/27/28×2, always the r9700 model server at 54–64 GB RSS, at the old
  `-cram 65536`). The cap is now **32768 (32 GiB)**. llama.cpp's cache
  auto-shrink-to-40% only fires when the cache's OWN allocation fails; it does
  **not** yield memory when other processes need it. Approaching-OOM symptom:
  requests stall and `free` shows the anon RSS of llama-server at its cap while
  the box swaps. **Mitigation: `zramSwap` in `hosts/zen3-nixos/default.nix`** —
  the kernel swaps cold cache pages to compressed RAM under pressure instead of
  killing, and the full cache still lives in free RAM when there is any. Don't
  remove the zram without a replacement cushion.
- **llama-log-viewer** on `127.0.0.1:8083` (the web app in this repo)
- **diamcp** container on `127.0.0.1:8082` (OCI container, podman)
- **nginx** (base config `services.nginx.enable` + temp/spill dirs in
  `hosts/zen3-nixos/nginx.nix`, TLS in `tls.nix`, and the `hosts/zen3-nixos/ai/`
  service modules — each service file owns its reverse-proxy locations and subdomain vhost;
  `netboot.nix` only adds the netboot-image vhost) exposing all of it on port 80
  - `server_name 192.168.49.50` → `/` → 8081, `/logs` → 8083, `/mcp` → 8082
  - the app is reachable at `http://192.168.49.50/logs/`
  - `/api/...` is SPLIT: llama-swap's own management endpoints (`/api/events`,
    `/api/performance`, `/api/version`, `/api/models/unload[/<name>]`,
    `/api/captures/<id>`) have explicit locations → 8081 (its UI, served from
    `/`, calls them same-origin); everything else under `/api/` is the
    Recallium UI REST catch-all → 9001. Don't remove the explicit locations —
    they were added after the Recallium `/api/` catch-all shadowed the
    llama-swap UI's `/api/events` SSE stream.
  - **Public HTTPS: `*.ai.chrisdell.info`** (DNS wildcard → this box's IPv6
    `2a02:8010:6680:49::50`). The wildcard fallback vhost in
    `hosts/zen3-nixos/tls.nix` serves the exact same locations as the
    `192.168.49.50` vhost (it references them via `config`) with `forceSSL`
    (80→443 redirect) for the apex and any name without a dedicated subdomain.
    Each AI service ALSO has its own subdomain vhost (defined in its own file
    under `hosts/zen3-nixos/ai/`, cert via `useACMEHost = "ai.chrisdell.info"`,
    exact server_name wins over the wildcard alias):
    - `llama.ai.chrisdell.info` → llama-swap UI + management API (root)
    - `llm.ai.chrisdell.info` → OpenAI-compatible endpoint for
      `config.ai.recalliumGpu` (`/chat/completions`, `/models`, …)
    - `logs.ai.chrisdell.info` → llama-log-viewer
    - `mcp.ai.chrisdell.info` → diamcp (`/mcp`)
    - `sd.ai.chrisdell.info` → SD web UI (root), `/sd-api/`+`/sdapi/`+`/v1/`
      API, `/sd-status/`
    - `recallium.ai.chrisdell.info` → Recallium UI + REST (root, no sub_filter)
    - `recallium-mcp.ai.chrisdell.info` → Recallium MCP (CORS handled by nginx)
    The cert is issued and
    renewed **locally** by `security.acme` (DNS-01 via Route 53, same Let's
    Encrypt account `me@chrisdell.info` as the router — account key copied to
    `/var/lib/acme/.lego/accounts/`) covering `ai.chrisdell.info` +
    `*.ai.chrisdell.info` into `/var/lib/acme/ai.chrisdell.info/`; the renew
    timer handles expiry and the generated postrun reloads nginx. AWS creds
    for lego are sops-encrypted in `secrets/zen3-ai.yaml` (force-added to git
    — sops-nix needs the file in the flake source; age key:
    `/var/lib/sops-nix/key.txt`, the shared key also on grafton-router —
    back it up, the config can't build without it). ⚠️ This puts the whole service set — incl. the unauthenticated
    Recallium REST API (`/api/`), log viewer (`/logs`), SD API (`/sd-api/`) and
    the LLM endpoints (`/recallium-llm/`, `llm.ai.chrisdell.info`) — on the
    public internet.

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

## 3d-printer-server (Klipper on a Smoothieboard, live)

Host `3d-printer-server` = `192.168.49.60` (config `hosts/3d-printer-server/`,
flake attr `3d-printer-server`; **no autoRollback** → no `nixos-confirm`). Runs the
`mkuf/prind` Klipper stack as three rootful podman units (`podman-klipper`,
`-moonraker`, `-mainsail`) with Mainsail on nginx :80. Board is a **Smoothieboard
(LPC1768)**, USB CDC-ACM, 16 KiB Smoothieware/DFU bootloader.

- **Full runbook: `docs/klipper-3d-printer.md`.** Read it before touching this host.
  Highlights: the host has **no GitHub credentials** (deploy commits via `git bundle`
  + `scp`, then `nohup sudo nixos-rebuild switch --flake .` — `systemd-run` fails on a
  libgit2 ownership check); the `config/build.config` in the printer checkout is a
  stale **RP2040** config, don't use it.
- **MCU firmware:** `sudo klipper-firmware-update [--status|--to-sd DIR|--flash]`
  (`hosts/3d-printer-server/klipper-firmware.nix`). Needed because the
  container tracks the floating `latest` tag and re-pulls on every start, so the host
  version drifts silently while the flashed firmware doesn't change — it had drifted
  **16 months**. It builds from the running image's version label so they can't drift
  again. Flash via the SD card (bootloader renames `firmware.bin` → `FIRMWARE.CUR`).
- **"Mainsail doesn't load" is usually not a Mainsail problem.** The UI's files serve
  fine; when klippy wedges (e.g. after an MCU-side `ADC out of range` shutdown) its API
  socket accepts connections but never answers, so Moonraker's requests hang 60 s and
  the SPA never finishes loading. Recovery: restart `podman-klipper` + `podman-moonraker`,
  then `FIRMWARE_RESTART`.
- **Open fault:** both thermistor readings sit at a stable but wrong ~81/86 °C and
  don't respond to heating (raw ADC 0.6889 = 10.41 kΩ, vs 0.955 expected for the 100 k
  sensors, which measure good). Not the sensors, not the host version (ADC code
  byte-identical across the working and current release), and not a non-sampling ADC
  (open inputs ramp to full scale). Leading suspect: the analog rail feeding the
  thermistor pullups (~2.4 V while the ADC is referenced to 3.3 V). Next tests are in
  the doc — measure the 3.3 V rail, then swap the sensors to the spare `P0.23`/`P0.24`
  ADC pins already commented in `printer.cfg`. **Do not leave a heater running:**
  with an in-range-but-wrong reading Klipper holds 100 % duty and `max_temp` can't trip.

## llama-log-viewer

`crates/llama-log-viewer/` is a **zero-dependency Rust** app (stdlib only — no crates
in `Cargo.toml`). Frontend (`index.html`, `app.js`, `style.css`) is embedded
into the binary via `include_str!`.

- **Any frontend change requires rebuilding the Rust binary** (the served
  files come from the compiled binary, not the repo dir on disk).
- The index (trie over message sequences) is rebuilt on demand when new log
  files appear; stats show e.g. `496 files / 1743 nodes / 24 roots`.
- Log files: one `.txt` per API call containing the complete context; formats
  handled: Qwen `<|im_start|>` and opencode `<system>…</system>` style.
- See `crates/llama-log-viewer/README.md` for API endpoints and design.

Rebuild + deploy on `zen3-nixos` (used successfully in the past):

```sh
# the nix package is built from crates/llama-log-viewer by hosts/zen3-nixos/ai/llama-log-viewer.nix
# (pkgs.rustPlatform.buildRustPackage with cargoLock.lockFile)
sudo nixos-rebuild switch --flake . --max-jobs 1
sudo nixos-confirm
```

## stable-diffusion-cpp (SDXL on the R9700)

`stable-diffusion-cpp` is installed on zen3-nixos as a **Vulkan build** — the
nixpkgs default is CPU-only (`SD_VULKAN=OFF`), so `hosts/zen3-nixos/ai/sd-gate.nix`
uses `(stable-diffusion-cpp.override { vulkanSupport = true; })`. The binaries
are `sd-cli` and `sd-server` (upstream renamed from `sd`).

- Models live in `/home/cjdell/sd-models`: SDXL base fp16
  (`sd_xl_base_1.0.safetensors`, 6.5G) + `clip_l.fp16.safetensors`,
  `clip_g.fp16.safetensors`, `sdxl_vae.fp16.safetensors` (from
  `stabilityai/stable-diffusion-xl-base-1.0`).
- Vulkan device numbering: sd-gate pins sd-server to the R9700 with the same
  device-select layer env (`MESA_VK_DEVICE_SELECT=1002:7551!`), so `vulkan0` =
  R9700 and the Vega is not visible to it. Same for all three llama-swap
  routers (see the gotchas section).

Working test command (1024×1024 SDXL, ~24 s for 30 steps on the R9700):

```sh
sd-cli --backend "diffusion=vulkan0,clip=vulkan0,vae=vulkan0" \
  -m /home/cjdell/sd-models/sd_xl_base_1.0.safetensors \
  --vae /home/cjdell/sd-models/sdxl_vae.fp16.safetensors \
  --clip_l /home/cjdell/sd-models/clip_l.fp16.safetensors \
  --clip_g /home/cjdell/sd-models/clip_g.fp16.safetensors \
  -p "a majestic golden retriever in a sunlit meadow" \
  -H 1024 -W 1024 --steps 30 --cfg-scale 6 --vae-tiling \
  -o out.png
```

**Gotcha — `--vae-tiling` is required for VAE decode.** RADV reports
`maxMemoryAllocationSize = 0xfffffffc` (~4 GiB) on the R9700, and the SDXL
VAE decode graph wants an ~8.5 GB buffer; ggml's single allocation (4.5 GiB)
then fails with `ErrorOutOfDeviceMemory` even though 32 GB VRAM is free.
`--max-vram` (graph-cut) does **not** fix it — only `--vae-tiling` (or putting
the VAE on CPU: `--vae-on-cpu`). Bigger graphs (Flux/SD3 at high res) will hit
the same cap.

### sd-gate: on-demand sd-server + web UI (live)

VRAM is at a premium (the R9700 also hosts llama-swap's resident coding
model), so SDXL is **not** kept resident:

- **systemd service `sd-gate`** (`hosts/zen3-nixos/ai/sd-gate.nix`; zero-dep Rust app
  in `crates/sd-gate/`): always listens on `127.0.0.1:8084` (nginx's `/sd-api`
  target). On the **first connection** it checks free VRAM (`amd-smi metric
  -m --json`): if < `--min-vram-gib 10` (i.e. the llama-swap LLM is
  resident) it posts to llama-swap's `POST /api/models/unload` and waits up
  to `--vram-wait-secs 90` for the VRAM before spawning `sd-server` on
  `127.0.0.1:8085` (same SDXL model, `--vae-tiling`, `--max-vram -1`); if the
  VRAM stays low it proceeds anyway (GTT-spill speed). Then it waits for
  readiness (`GET /v1/models` → 200) and proxies TCP traffic. **120 s after
  the last request it kills `sd-server` → VRAM freed**; the next request
  loads it back (a few seconds with a warm page cache). Lifecycle in
  `journalctl -u sd-gate`.
- **Status page:** `http://192.168.49.50/sd-status/` or
  `https://sd.ai.chrisdell.info/sd-status/` (JSON at
  `/sd-status/status`) — state, sd-server pid/times, idle-unload countdown,
  VRAM, and **active clients** (remote IP from nginx's `X-Forwarded-For`,
  request, age, phase): the reason the model is running and not shut down.
  Served by the gate on `127.0.0.1:8086`; the status listener never spawns
  the server.
- **Web UI:** `http://192.168.49.50/sd/` or `https://sd.ai.chrisdell.info/`
  (static files in `sd-webui/`,
  copied into the store via `runCommandLocal` so nginx can serve them). The
  UI pings `/sd-api/v1/models` on load and every 30 s (2 s while the server
  is down/loading, status pill shows “loading model…”), so opening the page
  wakes the model and a closed tab lets it idle-unload after ~2 min.
- **API:** `http://192.168.49.50/sd-api/…` or
  `https://sd.ai.chrisdell.info/{sd-api,sdapi,v1}/…` proxies to 8084 (the
  gate; it
  forwards to 8085, spawning sd-server if needed) with the `/sd-api` prefix
  stripped on the `/sd-api/` paths. The UI uses the A1111-style `POST /sd-api/sdapi/v1/txt2img` (full
  param control: steps/cfg/seed/sampler/negative_prompt); note the
  OpenAI-style `/v1/images/generations` on this build **ignores** steps/cfg/seed
  and only honors prompt/n/size.
- **Force-unload now:** `kill $(cat /run/sd-gate.pid)` — the gate survives and
  respawns sd-server on the next request. The unit's `ExecStop` kills any
  leftover sd-server if the gate itself is SIGKILLed, so VRAM can't be orphaned.
- **Shared-GPU gotcha:** the R9700 is also home to llama-swap's resident coding
  model (~26 GB VRAM), so SD runs at GTT-spill speed while the LLM is loaded
  (e.g. ~36 s for 8 steps at 512×512 vs ~25 s for 30 steps at 1024×1024 when
  free). The gate now unloads the LLM automatically when it loads SD (see
  above); manual equivalent: `curl -X POST http://127.0.0.1:8081/api/models/unload`
  (the LLM re-loads on the next LLM request). Model stays resident regardless,
  so nothing to preload.

## Recallium (memory server, live on zen3-nixos)

Recallium (`recalliumai/recallium` container, rootful podman like `diamcp`) is a
memory server for AI agents: MCP + web UI + Postgres. Its LLM processing runs on
the **Strata engine** (no cloud) — the same Qwen3.8-Flash-Next the rest of this
box uses, reached over loopback. It was **disabled from 2026-09-26 to 2026-10-15**
while llama-swap was torn down, and is live again since 2026-10-15 22:41 BST with
its LLM pointed at Strata. Full usage docs: `docs/recallium.md`.

- **UI:** `http://192.168.49.50:9001`, `http://192.168.49.50/recallium/` or
  `https://recallium.ai.chrisdell.info/`
- **MCP:** `http://192.168.49.50/recallium-mcp` or
  `https://recallium-mcp.ai.chrisdell.info/` (Streamable HTTP, protocol
  2025-11-25)
- **REST:** `http://127.0.0.1:8001/api/...` or
  `https://recallium.ai.chrisdell.info/api/...`; Postgres on `127.0.0.1:5433`
  (user `recallium` / `recallium_password`, db `recallium_memories`)
- **Chain:** container (OpenAI provider, fixed `base_url`
  `http://host.containers.internal/recallium-llm`) → nginx `/recallium-llm/`
  (in `hosts/zen3-nixos/ai/recallium.nix`) → **Strata on `127.0.0.1:8080/v1`** —
  the same upstream `https://strata.ai.chrisdell.info/` serves, hit on loopback
  instead of hairpinning TLS. Switching backend = edit that one location block
  + `nixos-rebuild switch`; no DB change (see docs/recallium.md). The old
  `ollama-bridge` (`:11434`) is legacy — Recallium no longer uses it, and
  `config.ai.recalliumGpu` is now read only by the disabled `llama-swap.nix`.
  ⚠️ Two things that location must keep or every Recallium LLM call breaks:
  **`proxy_set_header Host 127.0.0.1;`** (Strata's DNS-rebinding guard 403s the
  container's `Host: host.containers.internal` — `recommendedProxySettings`
  forwards the client's Host verbatim; `127.0.0.1` is allowed by default, the
  public names are what `allowed_hosts` in `strata.nix` carries) and
  **`client_max_body_size 32m;`** (nginx's 1 MiB default 413s a whole-session
  metadata prompt).
- **Active model:** whatever Strata serves — `qwen3.8-flash-next-ud-iq4-xs` while
  `config.ai.strataModel = "ud-iq4-xs"`. Recallium's DB row still says
  `Qwen3-4B-Instruct-2507-Q4_K_M` (config id 1002, model id 1006, provider
  account id 3) and that is **harmless**: Strata routes by engine, not by the
  requested name, so an unknown/absent model name still gets the loaded model
  (verified). Changing `ai.strataModel` needs no Recallium change at all.

Operational essentials:

- `POST /api/memories/` **always returns 500** (upstream response-schema bug) —
  the row is still created; read it back via `GET /api/memories/{id}`.
- There is **no API to change the LLM model** — edit `llm_provider_configs` in
  Postgres directly, then `sudo podman restart recallium` (see docs/recallium.md
  for the exact SQL). **Gotcha:** `active_llm_config_id` in `/api/setup/status`
  reads the first ACTIVE row of `llm_failover_priority`, NOT
  `llm_provider_configs.is_active` — repoint that row too or the status (and
  routing) won't change.
- **Zombie generations:** if a model is slow/looping, Recallium's 120 s client
  timeout disconnects but the engine keeps generating — and Strata serves ONE
  slot, so the orphan blocks every other request. llama-swap's
  `POST :8081/api/models/unload` is gone; Strata's `POST /v1/unload` answers
  `409 a request is running or queued` instead of interrupting it (there is no
  cancel), so the last resort is `sudo systemctl restart strata` — a multi-minute
  model reload.
- **Memory enrichment costs ~27 s per memory** on Strata (`llm_enrichment`
  25.1 s of it) and queues behind interactive traffic; `MEMORY_PROCESSOR_MAX_WORKERS
  = 8` in the container is embedding/tag parallelism, not LLM concurrency.
- `LFM2.5-2.6B-Q8_0` PGLoops on Recallium's JSON metadata prompt (see the
  llama-swap UI at `http://192.168.49.50/ui/#/logs`); don't switch it back.
- Setup is complete (`active_llm_config_id: 1002`); `mcp_tools_enabled: false` in
  `/api/setup/status` is cosmetic and does not block MCP.
- **The `recallium-healthcheck` oneshot must always exit 0.** Its timer's
  `OnBootSec` has long passed, so it fires the instant it is installed — during
  `switch-to-configuration`, alongside `podman-recallium` itself — and a curl
  exit 7 (container still booting) under `set -e` failed the unit, which made
  the whole activation report `status 4` even though everything applied. It now
  skips containers younger than 180 s and treats "not running" as "start it".

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

## DeepSeek Harness web GUI (`dsh-web-harness`, live on zen3-nixos + grafton-router)

The forked DeepSeek Harness Web GUI, as an always-on service:
`common/dsh-web-service.nix` (`services.dshWebHarness`), enabled by
`hosts/zen3-nixos/dsh-harness.nix` (`192.168.49.50:3080`) and
`hosts/grafton-router/dsh-harness.nix` (`192.168.49.1:3080`). Background and the
fork patch: `docs/dsh-fork/`.

- **The bare URL is `401` by design.** `dsh web` mints a random launch token per
  process and prints one URL carrying it; that URL is the bootstrap, and its
  token changes on every restart. Get the live one with **`dsh-web-url`** (prints
  the LAN URL; `--local` for loopback, `--open` to open it in a desktop browser).
- **What it mints is the bookmark.** The token sets an HttpOnly, SameSite=Strict
  `dsh-auth-…` cookie, bound to the authority it was issued for and signed with a
  durable secret (`~/.dsh/.credentials.yaml`), so it survives restarts and
  rebuilds. It lives `services.dshWebHarness.cookieMaxAgeDays` (default 3650
  days; upstream's is 30), so after **one** token visit per browser the plain
  `http://192.168.49.50:3080/` is all you need.
- **Don't undo the `!!js` line.** The module's cordis patch layer sets
  `cookieMaxAgeDays` on the `connection` row, and a patch **replaces** the matched
  row's whole `config` — so the row restates
  `trustedHosts: !!js ctx.webRuntime.trustedHosts` verbatim. Drop it and the
  `/api` fence has no declared authority: every LAN request 403s while loopback
  still looks fine.
- The legacy `dsh-web` wrapper (`common/dsh-web.{nix,sh}`) and its TCP proxy
  (`common/dsh-web-proxy.mjs`) were removed 2026-09-21: they drove `npx` against
  the *same* port 3080, so whenever both were up the service crash-looped with
  `EADDRINUSE`. Don't reintroduce a second thing that binds 3080.
- Deploy = `nixos-rebuild switch` on the host (+ `sudo nixos-confirm` on
  **grafton-router**, which has autoRollback; zen3-nixos has it commented out).

## meter-relay-rs (grafton-router, live)

The solar-inverter meter relay on **grafton-router** (the router itself,
`192.168.49.1`) is built from the Rust crate at `crates/meter-relay-rs` in this
repo — *not* the older TypeScript app in `/home/cjdell/Projects/meter-relay`
(kept for reference only), and no longer from the external checkout at
`/home/cjdell/Projects/meter-relay-rs` (the crate was folded into this repo;
the old checkout is just a backup). The
live `MR_*` credentials used to live in a `.env` in the old Rust checkout; they
are
in sops now and there is no `.env` on the host. It reads the grid meter
over serial Modbus RTU, re-serves those registers to the inverters, nudges them
with per-inverter PIDs so grid export tracks `MR_METER_TARGET_POWER`, charges the
batteries in the Octopus Go window, publishes to Home Assistant + InfluxDB, and
serves a Solid.js dashboard on `:8484` (`/api/status`, `/api/history`,
`/api/events` SSE, `/api/connections`, legacy `/stats`) with a second
`/#/diagnostics` page.

- **The endpoint→role mapping is discovered at startup, because the ports are
  not stable.** The inverter-pi (`192.168.49.30`, `ser2net`) bridges three (soon
  four) *identical* CH340 USB adapters with no serial numbers onto TCP
  2000/2001/2002/2003, so `/dev/ttyUSBn` — and therefore which inverter hangs off
  which port — re-enumerates across reboots. `MR_*_PORT`/`MR_STATS_PORT` are
  **hints**; at startup `src/discovery.rs` *listens* (read-only, 3 s, in
  parallel) for each inverter's own meter polls and *probes* only the endpoints
  that stayed silent (the stats bus and the local USB grid meter answer; a line
  with an inverter polling on it is never probed, and a TCP endpoint is never
  classified as the grid meter because an inverter answers the meter's own
  registers too). `MR_DISCOVERY_STRICT=true` (the deployed setting) refuses to
  start when a required connection cannot be placed — an inverter answered with
  another inverter's `MR_<ID>_REVERSE` is driven *backwards* — and
  `MR_DISCOVERY=off` restores the old trust-the-port behaviour.
- **`MR_DISCOVERY_ONLY=1` asks what the wiring looks like without starting the
  service**: it needs no credentials, prints the table, and exits non-zero if a
  required connection is unidentified. Stop `meter-relay` first — `ser2net` is
  `kickolduser: true`, so connecting displaces whatever holds the port.
- **Every connection reconnects on its own** (250 ms backoff doubling to 10 s).
  A dropped link used to leave the service running on a dead socket forever,
  which is what `/api/connections` and the diagnostics page exist to make
  visible: per connection, the discovered identity (and `mismatch` when it
  disagrees with the configured hint), state, last rx/tx, frame and directional
  counters, timeouts/CRC/exception/IO errors, reconnects and a windowed error
  rate. `src/diagnostics.rs` owns those counters; nothing there is on the control
  path.
- **A new inverter of an already-known model** works from `MR_<ID>_DRIVER` +
  `MR_<ID>_PORT` alone (its port is a candidate automatically; identical
  fingerprints are told apart by the configured port, which is what the hint is
  for). **A new model** also needs its meter-poll fingerprint —
  `MR_<ID>_METER_POLL="4:0:76,4:342:2"`, and a row in `driver_meter_poll()`
  (`src/config.rs`) — measured on the live line with
  `crates/meter-relay-rs/scripts/capture-serial.py`. Capture both of an
  inverter's states if it has them: a Solax with no meter scans for one
  (`fc3 reg 11` at both candidate addresses) and only polls active power
  (`fc4 reg 12`, `fc4 reg 74`) once it has found a meter. A model with no
  fingerprint at all cannot be placed, and strict mode will refuse to start.
- **The plant is a priority list, not two hardcoded inverters.** `MR_INVERTERS`
  orders it (default `solis,solax`) and each entry takes `MR_<ID>_*` overrides,
  so the existing `MR_SOLIS_*`/`MR_SOLAX_*` names still work. Entry 0 is the
  primary actuator; the rest are the reserve. Adding a third inverter is another
  id in the module's `plant` attrset plus `MR_<ID>_DRIVER` pointing at a known
  driver; a genuinely new *model* needs a row in
  `driver_defaults()` (`src/config.rs`) and an arm in
  `inverters::build()` (`src/inverters.rs`). Duplicate ports or slave addresses
  are a startup error.
- **Allocation water-fills in both directions**, so surplus PV the main bank's
  charge taper cannot absorb spills into the reserve instead of being exported
  (it exists to cover demand the main bank cannot, and the peak-rate import it
  displaces beats the 12p export). A reserve at `MR_<ID>_MAX_SOC` is skipped;
  `MR_<ID>_ABSORB_SURPLUS=false` makes an inverter discharge-only. `/api/status`
  now publishes `inverters: [...]` rather than named `solis`/`solax` keys —
  `/stats` and the Home Assistant entity ids are unchanged.

- Module: `hosts/grafton-router/services/meter-relay.nix` (imported by
  `services/default.nix`). **It is the relay's entire configuration** — the
  plant is declared there as an attrset applied via systemd `Environment`, so
  behaviour changes are Nix changes (`nixos-rebuild switch`), not edits on the
  host. The two credentials come from sops through
  `sops.templates."meter-relay.env"` + `EnvironmentFile`: the Home Assistant
  token reuses the existing `home_assistant_token` secret (byte-identical to
  what the old `.env` held), and `meter_relay_influxdb_token` is the relay's own.
  There is deliberately **no `WorkingDirectory` and no `.env`** on the host —
  the process CWD is `/`, so a stray `.env` has nowhere to be picked up from
  (dotenvy survives only as a local-development convenience). The dashboard is
  bundled into the store by the crate's own `nix/package.nix`
  (`buildNpmPackage` + a wrapper exporting `MR_WEB_DIR`) — a frontend change
  needs a rebuild, never a file copy.
- To change one setting, edit the `plant` attrset in that module. Non-secret
  values are visible in `systemctl show meter-relay -p Environment`; the tokens
  are not (they arrive via the rendered `/run/secrets/rendered/meter-relay.env`,
  mode 0400 root).
- **Build:** the crate lives in this repo at `crates/meter-relay-rs`. The root
  flake builds it — `hosts/grafton-router/services/meter-relay.nix` calls its
  `nix/package.nix` via `pkgs.callPackage` with
  `craneLib = inputs.crane.mkLib pkgs` (crane is a `flake.nix` input, no nixpkgs
  follow). There is **no separate `meter-relay-rs` input or `flake.lock` entry
  any more**, so a plain `nixos-rebuild switch --flake .` always builds the
  working tree. Live logs: `journalctl -u meter-relay -f`.
- **No Rust toolchain on grafton-router** (no `cargo`, no `rustc`, no `cc`), so
  the crate cannot be built with a bare `cargo test`. One command supplies
  everything for a fast edit/test loop — `cc` is needed to link build scripts and
  the `udev.dev` output for `tokio-serial`'s `libudev`:

  ```sh
  nix shell nixpkgs#cargo nixpkgs#rustc nixpkgs#pkg-config nixpkgs#stdenv.cc \
    nixpkgs#udev.dev nixpkgs#clippy --command bash -c \
    'cd crates/meter-relay-rs && cargo test && cargo clippy --all-targets -- -D warnings'
  ```

  `web/` needs `npm install` once (network); `npm run typecheck && npm run build`
  then work offline.

### Deploying a change (the step that gets missed)

`scripts/deploy-meter-relay.sh` does all of the below and verifies the result
(`--no-rebuild` evaluates and reports only; it refuses to switch on any host but
grafton-router). By hand:

```sh
cd ~/nixos-config
git status crates/meter-relay-rs     # untracked new files are invisible to Nix
git add -A crates/meter-relay-rs     # at least stage any NEW file — see below
git commit -m "…"                    # optional
# (a standalone `nix build` of the package is in the crate README)
sudo nixos-rebuild switch --flake .
sudo nixos-confirm                   # grafton-router has autoRollback — see the top
systemctl status meter-relay && journalctl -u meter-relay -f
```

- **A configuration-only change needs a rebuild, not a special path.** Editing
  the `plant` attrset changes no Rust code, so the built `ExecStart` is
  unchanged; `scripts/deploy-meter-relay.sh` will stop at "build is unchanged —
  nothing to deploy" and *not* switch — use `./scripts/deploy-meter-relay.sh
  --force`, or by hand `sudo nixos-rebuild switch --flake . && sudo
  nixos-confirm`. There is no restart-only path any more: the old `.env`
  shortcut is gone.
- **Verify the running build, don't assume:** `grep ExecStart
  /etc/systemd/system/meter-relay.service` must show the same store path the
  `nix eval` above printed, and `curl -s http://127.0.0.1:8484/api/status`
  should show the new fields (e.g. the PID `"saturated"` flag and the “at limit”
  badge added 2026-09-22).
- **An inverter can be effectively dead with nothing failing.** The relay learns
  what each inverter actually delivers/accepts and clamps the loop to that
  estimate — and because every rule only revises an estimate *down* to what was
  delivered, an inverter that delivers **nothing** at the command it is given
  gives the estimator no evidence to grow on, so the loop never asks for a
  command big enough to stir it. It sits there for as long as the process runs,
  raising no error and logging nothing; the only symptom is a number sitting
  still. Recognise it by an inverter whose `charge_limit` **and**
  `discharge_limit` are both *exactly* `150` (`= AUTHORITY_MARGIN_W`) with
  `battery_power` 0 while the grid is off target. On 2026-09-26 the Solax reserve
  sat like that for five hours *during the Go window*, at 17% SOC, delivering
  0 W — so the plant charged at 3.6 kW instead of 4.6 kW and the reserve failed
  to refill. Fixed in the relay (see `crates/meter-relay-rs/CONTROL-DESIGN.md`):
  a
  silent plant is now offered a ladder of larger commands every 30 s, and the
  60 W/s authority probe integrates over real time instead of over the PID's
  clamped step — that second one was also why the same window's charge crawled
  at 7 W/s and took 17 minutes to reach its rating. Reasoning, the regression
  table, and the diagnostic one-liner: `crates/meter-relay-rs/CONTROL-DESIGN.md`
  §2 and §7. **A relay restart clears a collapsed estimate** (the
  estimates initialise at the configured rating), which is the stopgap if it
  happens again before a rebuild.
- **A healthy inverter can be throttled by the estimator's own conservatism.**
  Because the central loop's ceiling *is* the learned authority, a plant whose
  charge ramps slower than the estimator's `DELIVERY_PROGRESS_W` (50 W inside the
  3 s confirm window = ~17 W/s) is read as refusing, the estimate collapses to
  `delivered + 150 W`, and the command then sits only ~150 W above the plant —
  so the plant ramps at ~6 W/s and the estimate can never grow faster. On
  2026-10-01 the Solis's `charge_limit` crawled 1.4→3.6 kW at ~6 W/s in **both**
  the Go window and midday PV; because the command tracked the estimate, actual
  `battery_power` tracked it too, and a sunny-cloudy afternoon exported surplus
  it could have stored. Diagnose with `solis_charge_limit` rising a few watts a
  second while the central PID is saturated (`saturated: true`, output ==
  min_output) and the grid exports. Fixed by lowering the progress threshold to
  10 W (`crates/meter-relay-rs/CONTROL-DESIGN.md` §2); the regression is
  `a_slow_charging_plant_is_not_throttled_to_its_own_lag`. A relay restart still
  clears a collapsed estimate as a stopgap.
- **The main bank still has no discharge floor, and `MR_SOLIS_MIN_SOC` will not
  give it one.** The Solis exposes no SOC register, so the relay cannot see the
  pack's state of charge at all (`"percentage": null`); it discharges until the
  JK BMS's own undervoltage protection cuts it off. Setting `MR_SOLIS_MIN_SOC`
  looks like the fix and is inert — it makes the slot *claim* to sense SOC, so it
  seeds at 50 % and then never updates, and the floor compares against that
  constant forever. That is how the bank was walked to 0 % on 2026-09-26 (BMS 2
  raised `Discharging undervoltage` and YaMBMS zeroed the discharge request, so
  the house imported ~1 kW for hours against a saturated PID). Closing it needs
  the BMS's SOC ingested into the relay, not a config knob. See
  `crates/meter-relay-rs/CONTROL-DESIGN.md` §2 "Known gap".

**Failure mode 1 — “I rebuilt but the input still runs the old code.”**
This **no longer applies to meter-relay-rs** (it is built from this repo now),
but it is still the rule for the other `path:` flake inputs (`gc-rust-node`,
`frigate-monitor`, the `llama.cpp` forks). Such an input is frozen at the
`narHash` recorded in `flake.lock`, so `nixos-rebuild switch` happily rebuilds
the *old* snapshot; because the resulting `ExecStart` is unchanged, systemd does
not even restart the unit, and the service keeps running the previous binary
with no warning. `nix flake update <name>` first, then compare the store path.

**Failure mode 2 — `vite build` / rustc says a new file does not exist.**
`error during build: Could not resolve "./Tip" from "src/App.tsx"` was exactly
this: `web/src/Tip.tsx` existed in the checkout but had never been added to git.
**New files must be at least staged (`git add`), or Nix cannot see them.** Nix
reads a flake's own directory through the **git fetcher**, which copies only what
git's index knows: tracked files (modified or not) *and staged ones*. A file
that is merely untracked is absent from `/build/source`, so the build fails on a
module that is plainly there in the working tree. Staging is enough; committing
is tidier. This applies to anything the build reads — `src/*.rs`,
`web/src/*.tsx`, `nix/package.nix`.

Note that because the crate now lives **inside** this repo, this flake *is*
git-filtered: a new file must be staged (failure mode 2) and `.gitignore`d build
junk (`target/`, `web/node_modules/`, `web/dist/`) is **not** copied into the
build. Keep `git status` in the crate clean-ish, so the working tree that Nix
reads corresponds to something reviewable.

## Strata (Qwen3.8-Flash-Next on the R9700, live)

The serving engine is **Strata** (a separate stack from llama.cpp), pinned at
**0.2.1.1** (`9ae93f7b1fe989d04a8e404d32cddaeeff10505f`, updated 2026-10-20 from
0.1.44.1 `296b59d2`). 0.2.0 split the repo into **app + Terminal + engine** — the
engine source in this tag is version 0.1.46.1, and `serve/server.py` now imports the
Terminal's `strata_control/` + `strata_cli/` Python packages, which `installPhase`
therefore ships too (without them the service dies at import). Built + patch-validated
2026-10-20; **the running system stays 0.1.44.1 until the next `nixos-rebuild switch`**
— verify with `systemctl show strata -p ExecStart` and `/v1/status` `"engine"`):
`hosts/zen3-nixos/ai/strata.nix` + `strata-package.nix` (imported by
`hosts/zen3-nixos/ai/default.nix`, gated on `config.ai.strata`), systemd unit
`strata`, OpenAI-compatible on `127.0.0.1:8080/v1`. Model
`Qwen3.8-Flash-Next-UD-IQ4_XS` (Unsloth ~4-bit GGUF) since 2026-10-09 19:23 —
switchable back to GSQ-RCO `IQ3_S`, which is faster (see the next bullet). Docs:
[`docs/strata.md`](docs/strata.md).

**One request at a time** (`/v1/status` → `concurrency.serving: 1`): Strata's
batching (`"parallel"` / `--batch N` / `--batch-mtp`) is available and **not
enabled** — slots cost 0.56 GiB of expert-cache VRAM each against **232 MiB free**
and drop the MTP draft path, which is what the 54.8 tok/s is made of. Analysis and
the numbers to watch if concurrency ever reaches 3+: [`docs/strata-batching.md`](docs/strata-batching.md).

⚠️ **0.1.43 and 0.1.44 change answers on our card** — three RDNA4 defaults now apply that
did not in 0.1.42: `STRATA_ROUTE_TAIL_SKIP=7` (stays off only from 90 % of experts in the GPU
cache; we are at 43 %, so it is ON; KL ~0.003–0.006), the measured PCIe share
(`STRATA_PCIE_FRAC_DEFAULT=old` reverts), and **new in 0.1.44: `STRATA_HC_Q8`** — the
hyper-connection projections are read as Q8_0 instead of BF16 on gfx1200/gfx1201 (R9700 decode
+2.5–4 %, mean KL 0.0003–0.0010, "answers can differ in near-ties"); for our `--compat-bf16`
pack the engine requantizes the pack's BF16 copy to Q8_0 at load. Revert with
`STRATA_HC_Q8=0`, or `STRATA_GFX12_DEFAULTS=0` for that **and** the new 16384 prompt chunk
(`STRATA_GFX12_CHUNK=0` keeps 8192; 0.1.44's #2090 guard already falls back to 8192 when free
RAM cannot cover the extra slot loan + 6 GiB). All three are documented in a comment in
`hosts/zen3-nixos/ai/strata.nix`. Upstream's R9700 rows: 0.1.43 decode +2–10 % / prompt
+12–14 %; 0.1.44 adds +2.5–4 % from HC_Q8. Details: `docs/strata.md` "0.1.43".

- **Two packs, one switch: `config.ai.strataModel`** (`hosts/zen3-nixos/ai/default.nix`
  sets `"ud-iq4-xs"`; the option default is `"iq3s"`). `hosts/zen3-nixos/ai/strata.nix`
  carries `models.iq3s` / `models.ud-iq4-xs` (GGUF + pack paths, `--ple-gguf` only for
  the 2-shard pack, and `--resident-budget-gib 55` for the UD one). The second pack is
  Unsloth **UD-IQ4_XS** (93.7 GB / 3 shards, fetched by
  `scripts/fetch-strata-udiq4xs.sh`, packed by `scripts/repack-strata-udiq4xs.sh`
  with **`--compat-bf16` required** — its 195 `hc_*` projections are Q8_0, which the
  AMD build cannot read natively in 0.1.41). **Live since 2026-10-09 19:23**, and it
  is **~20 % slower at decode than IQ3_S** (48-57 tok/s at 90-93 % expert-cache hits
  vs 62-68 at 92-97 %, same 66-70 K depth): 10,679 cache slots instead of 13,104, so
  1.7x the misses at 1.18x the bytes each. Prefill is unchanged (~1,250 tok/s) and
  262144 ctx is unaffected; RAM is calmer (39 GiB, `MemorySwapPeak` 0). Flip the line
  back to `"iq3s"` if decode speed matters more than the weights. Analysis, quant mix
  and measurements: [`docs/strata.md`](docs/strata.md) "UD-IQ4_XS".
- **A long-context reply can collapse to one repeated token (or a thinking-only
  turn with no answer).** This is the **fp16-overflow #606 class**, not a model
  quality issue: a `q8_1` activation block stores its scale and 32-value sum as
  fp16 (`max 65504`), and a block sum or scale can round to `+inf`, giving
  `inf * 0 = NaN` in the dot product (`ggml-org/llama.cpp#23606` is the same).
  The int8 KV cache has the same shape (a 64-value group's `amax/127` as fp16).
  **0.1.40 fixed upstream the two fused-SwiGLU sites our 0.1.39 build clamped
  itself**, and **0.1.41's #1448 clamped the remaining three emit sites** — incl. the
  opt-in S26 swiglu kernel (`iq_kernels.cu` `s26_swiglu_q8_1_kernel`, our clamp (1),
  now byte-identical upstream, so that `postPatch` block is gone) and the two
  `STRATA_QFUSE` sites we had left alone (`fused_gr.cu gr_q8_tail`,
  `verify_kernels.cu gdn_q8_1_store`). What is still ours, still unclamped upstream:
  the int8 KV scale — `kv_q8.cu:55` (decode) and `kv_append_kernel`,
  `prefill/kernels.cu:2199` (was 1702 in 0.1.44.1, 1691 in 0.1.43, 1340 in 0.1.42) — both
  live here because we run `--kv int8`. Still unclamped on 0.2.1.1: `kv_q8.cu` only added a
  `STRATA_EXPERIMENTAL_SM60`-gated gather below the shipped kernels, and `prefill/kernels.cu`'s
  769 changed lines are the Qwen3.6 prompt path + NVFP4 work, so both `postPatch` clamps are
  still needed and both `--replace-fail` targets are still unique.
  Full incident history, the exact sites, and verification
  commands: [`docs/strata-degeneration.md`](docs/strata-degeneration.md).
- **The recurring strata "core dumps" are not crashes — they are the engine's hang
  watchdog (upstream #29) killing itself after 60 s without GPU progress**, and each one is
  followed by an amdgpu MES queue-teardown failure and a MODE1 GPU reset (`VRAM is lost due to
  GPU reset!`). Always **prefill**, always `waiting for the GPU (attention, router)`, at 49K–186K
  tokens. The cores are useless (stripped binary, no build-id, 41 threads parked in libc stubs)
  and were **32 GB each on `/`** — `LimitCORE = 0` is now set in
  `hosts/zen3-nixos/ai/strata.nix`. ⚠️ `NRestarts=0` does **not** mean healthy: `bin/strata-server`
  restarts the engine child in-process, so systemd never sees the failure. Top fix candidate:
  `HSA_USERPTR_FOR_PAGED_MEM=0` (upstream #750 = two R9700s on ROCm 7.2; this box runs clr/hipblaslt
  **7.2.3**) is applied in `configFile`'s `env` since 2026-10-08 — verify with
  `sudo tr '\0' '\n' < /proc/$(pgrep -f '[b]in/strata --serve')/environ | grep -i userptr`.
  Full write-up: [`docs/strata-hang.md`](docs/strata-hang.md).
- **`hosts/zen3-nixos/ai/strata-kernel-audit.diff`** (`patches = [...]`, applied before
  `postPatch`) is **audit only — the guard is upstream now.** 0.1.43 shipped #1892: a
  finiteness guard on by default behind the *same* `STRATA_NAN_GUARD` switch our patch had
  invented, which emits nothing for the poisoned window, drops every cached state, re-reads
  the prompt from token 0 and retries the request once in `serve/server.py`
  (`non-finite logits (#879)`). Our guard only failed the window, and two guards behind one
  env var is a coin toss, so ours was dropped on 2026-10-12 and the file renamed from
  `strata-nan-guard.diff`. What remains is what upstream still cannot get: **where the
  poison is born** — per-stage first-non-finite (layer/row/col/raw bits) probes across the
  MoE path plus a dump in `Verifier::run` that rides on upstream's `nf_mask_` and prints
  *every* fire. It is allocated and launched **only** with `STRATA_KERNEL_AUDIT=1` (set in
  `strata.nix`) because each probe is an extra node in the captured verify graph. Re-based
  onto 0.2.1.1 on 2026-10-20 — the first re-base since 0.1.40.3 that needed real work:
  **5 of 19 hunks were rejected** by upstream context changes (verify.cpp's audit-alloc
  insert, the per-window reset, `audit_hit_rows`, and both `iq_kernels.cu` hunks — the file
  gained ~1,100 lines of S26/S27 v2/v2k expert paths, neither matching our IQ4_XS geometry)
  and were re-placed by hand; the other 14 landed with offsets up to +1159. Regenerated from
  the patched tree: 19 hunks, 280 additions, 0 deletions, byte-identical added lines,
  `--fuzz=0` with **no offsets** (`patch -p1 --fuzz=0` and `git apply --check` both clean).
  Its two anchors are intact: upstream's `nf_mask_` (`Verifier::note_nonfinite` in
  `verify.cpp`) and the `hits_in_combine` gate the routed-total probe checks.
  **#879 is closed but not dead** — closed 2026-10-13 as a stale-tracker sweep, and on
  2026-10-19 a fresh repro landed (engine 0.1.45, RTX 3080, an 18,442-token agent prompt with
  48 tools → fires every time; `STRATA_PREFILL_MMQ=0` answers the same body; birth in
  layer 1's MoE gate/up on the MMQ prompt path, types 22/42 = IQ4_XS gate/up — our pack's
  family; we build with `-DSTRATA_PREFILL_MMQ=ON`), so the audit stays needed.
  **Never re-apply an old file with fuzz** — `--fuzz=3`
  "succeeds" and puts the arena carve inside the `mapped()` chain and the input audit
  inside the PLE `try` block.
- **Two incidents, two sites.** Incident 1 (`!` ×256, ~156K context) was fixed
  by commit `437a753` (fused-SwiGLU `q8_1` store in `native_mmvq.cu` — upstream
  fixed the same site in 0.1.40, so that clamp no longer exists here). Incident
  2 (`索` ×256, 132.9K context, Pi session `01a1099d-927e-76ba-87c0-9abc71fa1df9`)
  hit **despite** `437a753` — the fix here also clamps the int8 KV scale
  (`kv_q8.cu`, `prefill/kernels.cu`) and the gfx906-only fused gate/up store
  (`iq_kernels.cu`, latent on gfx1201). Incident 3 (`!` ×255 at ~100K, in the
  *thinking* channel) fired **with every clamp in place**, which is what proved the
  root cause is a GPU routed-expert data-path defect (#879), not an fp16 scale.
- **A Pi session "crash" here is usually a folded reply, not an engine crash.**
  The reply comes back with `finish_reason: "length"` (repeat guard ends it
  after 256) and too few tokens, so Pi treats it as a recoverable truncated
  response: it omits the turn and starts a compact-and-retry loop that never
  recovers. Look in `bili.log` for a *degenerate terminal turn* retry before
  assuming Pi or the host died — there is no `crashes.json`, OOM, or coredump.
- **The engine does not run on nixpkgs' ROCm — it runs on a store-built ROCm
  10.0.0.** `hosts/zen3-nixos/ai/rocm10-runtime.nix` fetches the ROCm 10.0.0
  (TheRock) runtime and `strata.nix` puts it first with
  `lib_dirs = [ "${rocm10}/lib" ]`; `serve/server.py`'s `child_env()` PREPENDS
  that to `LD_LIBRARY_PATH`, overriding the build's RUNPATH to nixpkgs' ROCm
  7.2.3. That swap — not any clamp — is what stopped the #879 poison (0 fires in
  1911 requests vs 2/1399 on 7.2.3), so **do not "simplify" it back to
  `pkgs.rocmPackages`**: nixpkgs only has 7.2.3 (`rocmPackages_8/_9/_10` do not
  exist) and 7.2.x is the version that fires. Two stages on purpose: a
  fixed-output `curl` of the one 8 GB ROCm layer of
  `rocm/dev-ubuntu-24.04:10.0.0-full` (an OCI blob's sha256 *is* its manifest
  digest, so no skopeo/dockerTools needed) and then a `lib/*`-only tar extract —
  changing the filter costs a re-extract, never a second 8 GB download. Don't
  trim the 16 GB to the ~2 GB the engine maps: it dlopens by SONAME and a
  missing one fails at runtime. Until 2026-10-14 this lived at
  `/opt/rocm-10.0/lib`, laid down by hand by `scripts/setup-rocm10-libs.sh`,
  with an `ExecStartPre test -e` guard because `child_env()` silently drops a
  missing dir (that guard is gone — a store path cannot be missing).
  `/opt/rocm` → `pkgs.rocmPackages.clr` (a tmpfiles symlink in
  `ai/default.nix`) is a different, unrelated thing. Verify with
  `sudo cat /proc/$(pgrep -f '[b]in/strata --serve')/maps | grep -c rocm10-runtime`.
- **Verify the running engine, don't assume:**
  `systemctl show strata -p ExecStart` and `readlink /proc/$(pgrep -f '[b]in/strata --serve')/exe`
  must show the store path from the latest build (the build is offline and the
  host has no gcc, so it cannot be rebuilt on the box). `bin/strata-server` is a
  tiny wrapper — compare the native `bin/strata` when diffing builds.
- **Deploy:** edit `strata-package.nix`, `nix build .#strata --no-link`, then
  `sudo nixos-rebuild switch --flake .` (zen3-nixos has autoRollback commented
  out — no `nixos-confirm`). The switch restarts `strata`; the model load takes
  ~30 s and can make the box sluggish for 1–3 min.

## grafton-router has TWO tailscale connections (and only one is monitored)

`tailscale status` on grafton-router shows the **grafton** tailnet (our headscale
at `tailscale.home.chrisdell.info`, `100.64.0.0/24`, magicDNS `grafton.tailscale`).
The **leighhack** tailnet (theirs, `tailscale.leighhack.org`, `10.3.0.0/16`,
`int.leighhack.org`) is a *different* connection: it runs inside the
`grafton-hackspace-client` microVM and is reached via a hand-written
`ip route 10.3.0.0/16 via 192.168.49.15`. **A perfectly healthy
`tailscale status` says nothing about leighhack.** When leighhack is down, what
actually breaks is DNS: `adguard.nix` forwards `[/int.leighhack.org/]10.3.1.1:53`,
so the symptom is "a page won't load", not "a VPN is down".

Full write-up: **`docs/leighhack-tailscale.md`**. Diagnose with
`sudo ~/nixos-config/scripts/check-hackspace-tailscale.sh` (walks route → VM →
tailscale session → tunnel → DNS and names the failing layer). `hackspace-tunnel-check.service`
probes it every 2 min and pushes to the phone via `notifications.gateway`.

The 2026-10 outage, in one paragraph: the VM had **no disk**, so
`/var/lib/tailscale` was RAM-only and every restart had to re-register; nixpkgs'
`tailscaled-autoconnect.service` is `set -e`, `Type=notify`, and has **no
`Restart=`**, so on 2026-10-09 one registration attempt that never completed
killed the connection permanently — the host journal shows
`Starting tailscaled-autoconnect.service...` with no matching `Started` line,
whereas working boots get it 3 s later. The node was therefore **absent from the
hackspace's headscale**, not route-unapproved, and nothing retried for 5 days.
**Nothing in the config had changed** (VM module last edited 09-28, secrets
09-22); the key is reusable and worked first try, and the node is not ephemeral.
It "always used to work" because the VM ran for weeks without restarting — every
restart had always been a one-shot gamble against someone else's server.

Fixed by: persistent `microvm.volumes` image for `/var/lib/tailscale` (so
re-registering isn't needed at all — verified, same node `Created` survived a
rebuild), `Restart=on-failure` on autoconnect, root `authorizedKeys` + a router→VM
deploy key (there was previously **no way in**: password-only root, no VSOCK,
serial on qemu stdio) plus `tcpdump`/`dig`/`jq`, and the health timer.

**The return path is theirs.** The VM advertises `192.168.49.0/24`; if their
headscale has not enabled it for the current node, packets leave and die on the
way back — "tailscale down" from the router, "all fine" inside the VM. After a
*fresh* registration this took **~20 min** to settle on 2026-10-15 (a recovery
effect, not the outage cause), which is why the health check waits ~10 min before
paging. **Never restart the VM and immediately conclude it failed.**

## Known gotchas on this host

- **`/nix/store` is bind-mounted read-only for everything except `nix-daemon`.**
  PID 1's `mountinfo` shows `/dev/nvme0n1p3 … /nix/store ro,nosuid,nodev` (the
  ext4 itself is `rw`) and the daemon carries its own `rw` bind, so builds work
  but `sudo rm -rf /nix/store/<path>` fails with *"Read-only file system"* — not
  a filesystem error, `dmesg` stays clean. Delete paths with **`nix store delete
  <path>`**, which goes through the daemon. Related: a `nix build` backgrounded
  from an agent shell dies when the tool call ends, the daemon cancels the build
  on client disconnect and leaves a partial output in the store — run long builds
  in the foreground with a `timeout`, not `nohup … &`.
- **GPU pinning (single router, still Vulkan).** The mesa
  device-select layer (`VK_LAYER_MESA_device_select`, an implicit layer
  auto-loaded by every Vulkan app because NixOS patches the loader's search
  paths to `/run/opengl-driver/share`) reorders Vulkan devices so the
  **boot-VGA (console) GPU comes first** when `MESA_VK_DEVICE_SELECT` is unset.
  The R9700 drives no screens — the console lives on the iGPU — so `-dev
  Vulkan0` used to silently mean the Vega (that is how the r9700's models once
  ended up on the iGPU's GTT). Fix in `hosts/zen3-nixos/ai/llama-swap.nix`:
  the r9700 router wrapper sets `XDG_DATA_DIRS=/run/opengl-driver/share` and
  `MESA_VK_DEVICE_SELECT=1002:7551!`; the trailing `!` exposes only that device,
  so `-dev Vulkan0` always means the pinned GPU. The HIP-fork era is over
  (`HIP_VISIBLE_DEVICES`, `HSA_OVERRIDE_GFX_VERSION` are gone). Don't
  "simplify" this back to plain indices.

- **CPU swap 2026-10-08 (5700G → 5950X): the PCIe bus re-enumerated, so BDFs and
  render minors are NOT stable.** The R9700 moved `0000:03:00.0`→`0000:09:00.0`
  (renderD128→renderD129) and the RX 580 `06:00.0`→`04:00.0` (it owns
  renderD128 now and is the console — the 5950X has **no iGPU**, so every
  "Vega iGPU" note in this file is history). `03:00.0` is now an AMD-500-series
  switch port, which is why `gpu-panel` crash-looped on a hardcoded BDF and
  `gpu.ai.chrisdell.info` 502'd. **Match GPUs by PCI id/UUID, never a BDF or a
  renderD minor**: `gpu-panel --pci 1002:7551` (id-based sysfs scan), the R9700's
  DRM node via the udev symlink `/dev/dri/r9700` (`services.udev.extraRules` in
  `hosts/zen3-nixos/ai/gpu-panel.nix`), HIP by `amd-smi list` UUID
  `47ff7551-…`. One swap side effect still open: the **TPM changed**, which had
  invalidated libvirt's sealed `secrets-encryption-key` and made every
  `nixos-rebuild switch` exit 4 (regenerated 2026-10-08; the old blob is kept as
  `/var/lib/libvirt/secrets/secrets-encryption-key.stale-tpm`).
  The other side effect is **fixed (2026-10-08, box rebooted 23:26 BST): ReBAR is back on** — Above-4G
  Decoding + Re-Size BAR enabled in the BIOS, so `lspci -vvvs 09:00.0` shows
  `BAR 0: current size: 32GB, supported: 256MB 512MB 1GB 2GB 4GB 8GB 16GB 32GB`
  mapped at `f000000000`, and amdgpu logs `Detected VRAM RAM=32624M, BAR=32768M`
  (was `BAR=256M` after the swap) — the whole card is host-visible, no 256 MB
  window. If BAR0 reads 256 MB again, the BIOS setting got reset.

- **The r9700 HIP fork is gone (all llama.cpp forks removed 2026-09-26).**
  `rdna-boosts`/`llama-cpp-rdna` (stew675) was the r9700 build until
  2026-08-23 (zero MTP draft acceptance on HIP: spec_decode counters stayed 0);
  `llama-cpp-mtp` (local `/home/cjdell/Projects/llama-mtp`) carried the open
  qwen4exp-MTP PRs from 2026-09-03; `llama-cpp-uma` was an unused local
  checkout of upstream. All three inputs are deleted from `flake.nix` — the
  router runs upstream `llama-cpp` (Vulkan) only. The checkouts are still on
  disk for reference. The old build recipe was: `rocm` overridden to
  `rocmGpuTargets = "gfx1201"` + `-DLLAMA_BUILD_TESTS=OFF` (upstream's flake
  builds the full test suite and parallel test compilation ICEs gcc on
  test-jinja.cpp). Benchmarks: `scripts/bench-r9700.sh` /
  `bench-compare.sh`, results in `bench-results/r9700/`.

- **`sudo nginx -T`/`-t` is misleading *and* has a side effect.** It reads the
  package's stock `conf/nginx.conf` unless you pass the generated one, so the
  documented invocation is
  `sudo nginx -T -c "$(systemctl cat nginx | grep -oE '/nix/store/[a-z0-9]+-nginx\.conf' | head -1)"`
  (the older `/run/current-system/etc/systemd/system/nginx.service/nginx.service`
  path is **not a directory** any more — grep fails with "Not a directory" and
  the command runs with no config at all). ⚠️ **The side effect:** NixOS emits
  no `user` directive, so a root-run nginx chowns every `*_temp_path` dir under
  `/var/cache/nginx` to its unset-user fallback **`nobody` (65534), mode 0700**.
  The worker (uid 60) then cannot create the client-body spill file, and every
  request with a body over `client_body_buffer_size` (i.e. every agent prompt)
  gets a bare `500` with `[crit] open()
  "/var/cache/nginx/client_body_temp/00000000NN" failed (13: Permission denied)`
  in the **journal** (the generated config sets `error_log stderr;`, so there is
  no `/var/log/nginx/error.log` to grep on the live service). This took out every
  pi session on 2026-10-15 (22:57–23:04, right after a post-deploy `nginx -t`).
  Recover without a rebuild:
  `sudo find /var/cache/nginx -mindepth 1 -maxdepth 1 -exec chown nginx:nginx {} +`
  (use `sudo find`, not `sudo ls /var/cache/nginx/*` — that glob expands in your
  own shell and the dir is 0750 nginx:nginx). `hosts/zen3-nixos/nginx.nix` now
  fixes it at the source: it declares `user nginx;` in the main context (nginx
  warns "the \"user\" directive makes sense only if the master process runs with
  super-user privileges, ignored" once per start — expected, don't remove it) and
  keeps the spill dirs `0770 nginx:nginx`, so a wrong owner no longer locks the
  worker out. On any *other* host (no `user` directive in its config), run root
  tests as `sudo nginx -t -c <conf> -g 'user nginx nginx;'`.
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

- **Partition layout / NVMe naming:** `/` is on the WD Black p3 (250G, at the *end* of the disk), `/home` on p5 (~681G), `/boot` the ESP (548M). There are two NVMe drives and their kernel names (`nvme0n1`/`nvme1n1`) **swap between boots** — always resolve by fs UUID (`4424123b…`=/, `a4284946…`=/home, `F281-1075`=ESP), never by device path.
- **`resize-once.nix` is a disabled one-shot initrd resize** (completed 2026-08-14: / 181G->250G, /home 750G->681G). Import commented out in `default.nix`; full write-up + reuse steps in `docs/resize-once.md`.
- **The ESP fills up** as generations accumulate (each initrd ~65MB); prune the system profile (`nix-env --profile /nix/var/nix/profiles/system --delete-generations +N`) to keep the 548M ESP bootable.

## Web fetching (context safety)

`fetch` returns the **entire page** into the conversation with no size cap —
a single large fetch can overflow the model's context window, killing the
agent thread with no way to resume it. Follow this order:

1. `fetch` is fine only for small, known endpoints (API/JSON, short pages).
2. For unknown or potentially large pages, download with the terminal and
   inspect surgically:
   `curl -sL <url> -o /tmp/page.html` → then `grep` or `read_file` (which
   outlines large files) for just the parts you need.
3. If content must appear inline, bound it:
   `curl -sL <url> | head -c 20000` (or the terminal's `head_lines` /
   `tail_lines` parameters).
4. Never return multi-megabyte content into the conversation.

## Workflow conventions

- **Prefer helper scripts over inline one-liners for repeated/complex operations**
  (HA API calls, multi-step deploys, TFTP testing, …). Keep them in `scripts/`
  (committed) or `/tmp/` (scratch), make them idempotent, and give every
  network call a `timeout`. Existing: `scripts/update-pi5-node.sh` (enroll a
  join code, re-lock the gc-rust-node input, `nixos-rebuild switch` +
  `nixos-confirm`, power-cycle the Pi, verify),
  `scripts/pi5-powercycle.sh` (HA relay: default full cycle, `--off`/`--on`),
  `scripts/deploy-meter-relay.sh` (rebuild the `crates/meter-relay-rs` crate on
  grafton-router, confirm, verify — see that section).
  Do not paste HA tokens/curls inline in agent sessions — call the script.
- **Set timeouts on everything that talks to the network** (`timeout N cmd`);
  bare `ssh`/`curl`/`ping` to a flaky or dead host will stall the session.
  Never `pgrep -f`/`pkill -f` with a pattern that matches your own shell's
  command line (it self-matches and loops).
- **Poll for long-running work with a bounded loop, never one long `sleep`.**
  A single `sleep 300` blocks the turn (and gets aborted) with no progress
  visibility. Run the job in the background with output to a log, then loop a
  short sleep with a status line each iteration, e.g.:

  ```sh
  for i in $(seq 1 40); do
    kill -0 "$pid" 2>/dev/null || { echo "[done] ($i)"; break; }
    printf '[%s] ' "$i"; tail -1 /tmp/job.log
    sleep 15
  done
  ```

  Check liveness with the job's PID (`kill -0`) or a `pgrep` pattern that
  cannot match the polling shell itself — not a long blocking sleep.
- Do not run heavy builds unless the task requires it; the user applies Nix
  config themselves when they prefer.
- If you DO apply a config (with permission), always finish with
  `sudo nixos-confirm` on autoRollback hosts.
- The repo often has uncommitted/staged changes (e.g. `hosts/zen3-nixos/ai/`,
  `default.nix`)
  plus untracked scratch files (`dump.txt`, `logs.txt`, `ppp.sh`, `result*`).
  Leave them alone unless the task is about them.
