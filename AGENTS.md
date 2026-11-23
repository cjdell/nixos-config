# AGENTS.md

Guidance for AI coding agents working in this repository. Read this before making changes.

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

A NixOS flake-based configuration managing many hosts (NAS boxes, ThinkPads, a Zen 3 GPU
workstation, etc.). Key layout:

| Path | Purpose |
| --- | --- |
| `flake.nix` | Flake definition; builds every `hosts/<name>` dir as a NixOS config |
| `hosts/` | Per-host configuration. **Directory name == host name** (e.g. `zen3-nixos`) |
| `common/` | Shared modules (`system.nix`, `desktop.nix`, `sops.nix`, …) |
| `users/` | User configs (home-manager) |
| `machines/` | Legacy configs for older machines (referenced from `flake.nix`) |
| `crates/` | Every Rust crate in this repo (`llama-log-viewer`, `gpu-panel`, `ollama-bridge`, `meter-relay-rs`), built by the root flake (see below) |
| `footage/` | Video cleanup kit: `footage-clean`/`footage-probe` CLI (VapourSynth deint+denoise → video2x RealESRGAN/RIFE on Vulkan → FFmpeg encode). `nix build .#footage-kit`, usage in `footage/README.md` |
| `llama-logs/` | Live `llama-server --log-prompts-dir` output consumed by the viewer |
| `docs/recallium.md` | How to use the Recallium memory server (APIs, MCP, examples) |
| `docs/klipper-3d-printer.md` | 3d-printer-server / Klipper (Smoothieboard LPC1768): boot-race fix, `klipper-firmware-update` + SD-flash runbook, and the **open** thermistor/ADC fault |
| `docs/gtt-vram.md` | GTT-default/VRAM-cache research: `GGML_VK_ALLOW_SYSMEM_FALLBACK`, why there's no weight cache in llama.cpp, and why GTT never auto-unspills |
| `docs/zen3-random-crashes.md` | **OPEN** investigation into zen3-nixos' random hard resets (watchdog-reaped hangs, not panics; memory/IMC hypothesis; `[S]`=CPU_OUT_OF_SPEC) + the `scripts/stress-monitor.sh` soak harness — sequel to `docs/kernel-rcu-wedge.md` |
| `docs/billion-context.md` | The `billion-context` context-compression proxy (ACP `compress` tools + fold nudges): config location/merge order, why folds fired at ~50 % of a 256K window (`nudgeGrowthTokens` + `outputHeadroomMaxPct`), the 2026-09-30 tuning, the exact nudge-gate formulas, and how to health-check it (`bili doctor`, `/__bili/*` on the **pi lane port 18789**, not 18787) |
| `docs/strata-hang.md` | Strata's `no progress for 60 s` watchdog aborts (upstream #29) → 32 GB core dumps → amdgpu MES teardown failure + MODE1 GPU reset: why the cores are useless, the journal line that names the stall, and the `HSA_USERPTR_FOR_PAGED_MEM=0` candidate fix (#750 = two R9700s on ROCm 7.2) |
| `docs/strata-batching.md` | Strata **batching / concurrent sessions** (`"parallel"` → `--batch N`, `--batch-mtp`, `--batch-groups`) + the 2026-11-10 **`strata-batch` toggle**: why zen3-nixos stays at `concurrency.serving: 1` — measured on 0.2.13.1, slots take **2.34 GiB** VRAM + 85 MiB×2 DFlash2 slot-drafters (**STRATA_BATCH_DF2** drafts are the 0.2.13.1 default — the October "no MTP drafts" analysis is obsolete) and ~10 GiB pinned RAM, so the expert cache drops −10.3 % and a *lone* stream decodes **39.2 vs 56.9 tok/s**, two streams reaching only 14.7–26.6 each — less aggregate than one solo; lazy allocation inside the engine is impossible (startup carve, never handed back), the RTX 5070 table (2 concurrent = −15 % aggregate) vs the `--batch-mtp` +31–39 % claim and the 2× R9700 −21.9 % counter-example, the #1603 risk the single-slot setup avoids, and how to enable + verify it |
| `docs/strata-expert-helper.md` | Options for a **second GPU as a Strata expert helper** on zen3-nixos (from #879): the three walls (mixed-vendor unsupported, ROCm arch coverage, and the board's second slot training at **Gen1 x2 = 0.5 GB/s**), candidate cards (RX 580 unusable / RTX 2060 needs a cross-vendor patch / RX 5600 gfx1010 clean but link-bound), the #1184 +10–18 % reference numbers, and why the PCIe link is the dealbreaker |
| `docs/leighhack-tailscale.md` | The **second** tailscale net on grafton-router (the hackspace's, `10.3.0.0/16`, via the `grafton-hackspace-client` microVM): why `tailscale status` being healthy proves nothing about it, the diskless-VM + single-use-pre-auth-key root cause of the 2026-10 outage, `scripts/check-hackspace-tailscale.sh`, and the QMP trick for a console in a VM with no password |
| `docs/jellyfin-tvdb-rematch.md` | Re-matching Jellyfin TV episodes after a **TheTVDB renumber** (the 2026-10-27 DS9 fix): why filenames can be right while titles are shifted, the three conditions re-matching needs (plugin installed, TheTVDB re-added to the library's `TypeOptions` fetchers — pruning is the trap — stale `Imdb` ids wiped via `"Imdb":""`), the Apply→wait→FullRefresh flow, title-card frame verification, and the `scripts/jellyfin-tvdb-fix/` toolset |
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
| **grafton-router** | `.1` (`2a02:8010:6680:49::1`; Zen's **delegated** /48 — everything pinned to it is a self-expiring credential, verify per `hosts/grafton-router/networking/constants.nix` before re-pinning anything) | Edge router **and** the main homelab app host | PPPoE WAN (`pppoe-zen`), `lan` bridge + VLAN10, nftables, dnsmasq DHCP+DNS, AdGuard, WireGuard `10.47.0.0/16`, headscale + Tailscale, **kanidm** IdP (`kanidm.home.chrisdell.info`), nginx public edge `*.home.chrisdell.info` (ACME DNS-01 Route 53 + route53 dynamic DNS) proxying to itself *and* to N100-NAS (`grafana…`→`:3000`, `filebrowser…`→`:8002`), Home Assistant + InfluxDB + Mosquitto + zigbee2mqtt, Frigate (+`frigate-whisper`/`frigate-monitor`), Jellyfin, Immich, qBittorrent, Ghost, 2fauth, Beszel, Postgres, **meter-relay** (`:8484`), container-ui, TFTP/iPXE netboot, a microVM host (`grafton-hackspace-client`, `.15`), dsh-harness `:3080` | **autoRollback ON** → `sudo nixos-confirm`. 15 GiB RAM + 8 GiB `/swapfile`. No Rust toolchain. Config is `hosts/grafton-router/` (imports its own flake inputs). |
| **zen3-nixos** | `.50` (`…:49::50`) | AI workstation + primary build box | Avalon `:8080` (Qwen3.8-Flash-Next, R9700 32 GB; llama-swap `:8081` is **disabled**, and Strata `:8080` was **disabled 2026-11-04** in favour of Avalon — see the Avalon section), sd-server + Flux-schnell (only when `gpu-mode sd` holds the card — see the GPU-modes section), Recallium (its LLM = Avalon via `/recallium-llm`), diamcp, llama-log-viewer, gpu-panel, nginx `*.ai.chrisdell.info`, Pi 5 netboot (TFTP `/etc/tftp`, NFS store snapshot `/exports/nix-store`) | autoRollback **commented out** → no `nixos-confirm`. zram swap. Dispatches aarch64 builds to the MacBookAir; is itself the builder for alderlake-thinkpad and macbook-pro-2009. |
| **N100-NAS** | `.22` | Media/app NAS (ZFS pool `samsung-4tb`: `ds-media`, `ds-photos`) | Jellyfin, Immich (podman: server/ml/redis/postgres), **Silo** (`hosts/N100-NAS/silo.nix` — 2026-11-20 media-server trial; digest-pinned omnibus container, web `:8090` = `silo.home.chrisdell.info` via the router, JF-compatible API `:8097`, Kanidm OIDC via the router's `silo` OAuth2 client), qBittorrent, Postgres + postgresqlBackup, filebrowser, Grafana `:3000` (kanidm OIDC, `grafana.home.chrisdell.info`), container-ui `:8091`, Samba + NFS, sanoid + syncoid → N40L-NAS and dbthr33, Scrutiny, Prometheus exporters, Tailscale | **autoRollback ON** → `sudo nixos-confirm`. Repo checkout lives here too. `common/folding-at-home.nix` (the linuxserver container) is imported — it was crash-looping on every host over an unqualified image name, fixed 2026-10-20, so it will start CPU-folding on the next switch of every host that imports it. |
| **GEN8-NAS** | `.23` | Bulk file + snapshot host (ZFS `sas-24tb`: `ds-public`, `ds-cjdell`, `ds-backup`) | Samba + NFS shares, sanoid snapshots, syncoid → N40L-NAS, `backup-host` receiver (`backup` user, `/var/lib/backup`), Scrutiny, Prometheus exporters, Tailscale, `lsiutil`/`sasutils` (HBA) | no autoRollback. ZFS via disko. |
| **N40L-NAS** | `.21` (`…:49::21`) | The backup **target** (ZFS `sas-16tb`) | Receives the GEN8 + N100 syncoid streams under `sas-16tb/ds-external-backups/…`, holds dbthr33's `ds-frigate-archive`, UniFi controller container, `zfs-status`, Scrutiny, Tailscale | `nfs.nix`, `samba.nix` and `backup.nix` exist in the directory but are **not imported** by `default.nix` — no shares and no offsite push from this box. no autoRollback. |
| **zen1-nixos** | `.51` | folding@home **space heater** (Ryzen 1800X 16t + RX 5700 XT) | Native FAH v8 client `fah-client.service` folding on all 16 threads + the GPU (donor `cjdell`, team 236565, linked to the FAH account). `common/folding-at-home-native.nix` + `common/fah-packages.nix`: nixpkgs has neither the FAH client nor a ROCm OpenCL ICD any more, so both are fetched from upstream binaries (client deb from foldingathome.org; the ROCm **6.4.3** OpenCL runtime from repo.radeon.com — the last release with OpenCL, and what the FAH AMD-GPU guide documents). Gotchas: a fresh v8 client starts **paused with GPUs disabled** (the `fah-client-configure` oneshot sends the websocket `config`/`fold` commands); the OpenMM core needs `LD_PRELOAD` of the distro libstdc++ (Navi 10+ bug, see the module comment); Web Control `http://192.168.49.51:7396/`; state in `/var/lib/fah-client` (DB + cores + `log.txt`). `fah-panel.service` (same shared crate `crates/fah-panel` + `common/fah-panel.nix` as the asus-i7-6700, `gpu = "amd"`, `amdPci = "1002:731f"`) on `http://192.168.49.51/` — port 80, amdgpu sysfs telemetry + the live `power1_cap` slider (75–150 W on this VBIOS; cap writes verified working with the default ppfeaturemask) + **`cpuTempTarget = 80`** (the 1800X otherwise runs pinned at Tjmax ~95 °C; the panel holds `Tctl` at 80 via `scaling_max_freq`, startup target in ExecStart = survives reboots, slider overrides live). no autoRollback. |
| **haswellatx-nixos** | `.54` | folding@home space heater + Plasma console (i5-4460, R9 290/390) | Native fah-client (donor cjdell, team 236565, sops account-token linked): 3–4 CPU threads (FahCore_a8) **plus the R9 290/390 (Hawaii/gfx700) on FahCore_28 via Mesa Rusticl** — ROCm dropped gfx700 in 2018, but FAH only needs an OpenCL device with fp64 + `cl_khr_pci_bus_info` (bastet#239), which Rusticl provides without KFD: `RUSTICL_ENABLE=radeonsi` (gallium driver names — the blog-post value `AMD` matches nothing) + `RUSTICL_FEATURES=fp64`, ICD `pkgs.mesa.opencl`. Full recipe + gotchas in `hosts/haswellatx-nixos/folding-heater.nix` — do not "simplify" that env away. Converted from `machines/` 2026-10-25; bare-minimum build (Plasma inline, no wine/sunshine/nfs). no autoRollback. WOL `90:de:80:e1:4e:42` powers it back on from a hard-off. |
| **3d-printer-server** | `.60` | Klipper 3-D-print server | prind stack as three rootful podman units (`podman-klipper/-moonraker/-mainsail`), Mainsail on nginx `:80`, `klipper-firmware-update` | no autoRollback; no GitHub creds (deploy via `git bundle`); read `docs/klipper-3d-printer.md` first. |
| **asus-i7-6700-nixos** | `.65` | folding@home space heater + Plasma console (ASUS Z170 PRO GAMING, i7-6700 Skylake 4c/8t, 16 GB, **GTX 1060 6GB + GTX 970**, console on the HD 530 iGPU) | **Renamed 2026-10-28 from hp-z240-xeon-1240v6-nixos** — the old HP Z240 SFF was rebuilt as this ATX box (same WD 120 GB SSD, by-label BOOT/ROOT mounts survived the swap); every workaround the HP needed (dead PCH xHCI, 240 W PSU brownout caps, poweroff hang, WOL quirks) is gone with it. Native fah-client (donor cjdell, team 236565, sops account-token linked): all 8 threads **plus BOTH GTX cards on FahCore_28 via CUDA** (the OpenMM core picks the CUDA platform directly for Pascal and Maxwell alike; the NVIDIA driver's own OpenCL ICD is wired up through `OCL_ICD_VENDORS` for the client's GPU detection — haswellatx's Rusticl-env pattern, but pointing at `${config.hardware.nvidia.package}/etc/OpenCL/vendors`; keep those env overrides). FAH's SQLite DB keeps prior client settings and config.xml only SEEDS — after the rename `/var/lib/fah-client/db.sql.fah` had to be wiped once to drop the HP-era `cpus=4`/`gpu-usage=50`. Driver stays pinned to `nvidiaPackages.legacy_580` (580 = last Maxwell/Pascal branch; `latest` = 595/615 dropped GM204/GP106) with the local `overrideAttrs` workaround for the **patchelf-0.19.2 nvidia-smi segfault** (NixOS/nixpkgs#576412 — same nixpkgs pin; re-patches `bin/` programs from `origBin/`, rpath-then-interpreter; remove once fixed upstream; note nvidia-smi lives in the driver's **bin** output, use `.bin`). `fah-panel.service` (crate `crates/fah-panel`, `http://192.168.49.65/` — port 80; one shared app for every heater, service module `common/fah-panel.nix`, here `gpu = "nvidia"`): its nvidia backend shows **one live card + one power-cap slider per GPU** (`-i N -pl`, each card its own range; the DC-load card sums both boards with the CPU). No boot-time power caps and no `--budget` marker: a proper ATX PSU has nothing to watch against (that is why 1060 TDPs summed ≈ 265 W is fine here). Converted from `machines/` 2026-10-25; bare-minimum build (Plasma inline, no wine/sunshine/nfs/podman). no autoRollback. New NIC `enp0s31f6` (I219-V) MAC `70:8b:cd:a8:50:bc` — the old WOL address died with the HP board; WOL untested on the ASUS so far. **`gpu-mode` CLI** (host `gpu-mode.nix` + `./gpu-mode.sh`, the zen3 lease's sibling — same name, fewer modes): `gpu-mode fold|llm|off` (bare = status). `fold` is the boot default (fah-client has wantedBy; the `llm` unit deliberately has none); `llm` STOPS fah-client whole-client (v8 has no per-GPU switch the script can trust — settings live in the DB, not config.xml; in-flight WUs checkpoint and requeue) and starts `llama-server.service`: llama.cpp **Vulkan** (`llamaCppPkgs.vulkan` — CUDA 13's nvcc dropped Pascal/Maxwell, so the 580 driver's Vulkan ICD is the only llama path on these cards) with `--device Vulkan1` = the 1060 (PCI `01:00.0`; gpu-mode verifies the server landed on that bus), model `~/Models/LFM3-1.7B-Q4_K_M.gguf`, OpenAI API + web UI on `:8080`. LFM3 is native 256K ctx (only 11 of its 24 layers hold KV): full 262144 ctx commits 4457 MiB, measured on the 6 GiB card 2026-10-31 — and the llama-cpp flake input must stay ≥ upstream b11960 or lfm3 fails to load. `gpu-mode fold` re-runs `fah-client-configure` (idempotent fah-provision: enables GPU slots + `fold`), which also clears a Web Control pause. |
| **kabylakeitx-nixos** | `.55` | folding@home space heater + video workbench (i7-7700 Kaby Lake 4c/8t, 32 GiB, **RTX 2060 6 GB Turing**, Plasma console) | Converted from `machines/kabylakeitx` 2026-11-03 and put on the native v8 F@H client the same day (donor cjdell, team 236565, linked to the FAH account via the sops `fah_account_token` — the shared fleet age key was installed on this box 2026-11-03; `hosts/kabylakeitx-nixos/folding.nix`). The NVIDIA wiring there mirrors asus-i7-6700: `OCL_ICD_VENDORS` at the driver's own OpenCL ICD, `LD_LIBRARY_PATH` forced to ocl-icd+driver, `HOME` in a CacheDirectory so the JIT cache survives restarts; `common/folding-at-home-native.nix` ships the ROCm ICD by default, so those overrides are load-bearing (client sees the 2060 on OpenCL *and* CUDA). No `fah-panel` and no `gpu-mode` lease here — pausing the heater is `sudo systemctl stop fah-client`, which is what to do while a render runs (that was the 2026-11-03 state: stopped for the Disney deinterlace). Video work: `nix build .#footage-kit` closures stream over from zen3 (the store delta pattern), `/ds-public` is the GEN8-NAS NFS share with `pctv-masters/` + `pctv-deinterlaced/`. The RTX 2060 is Turing (compute 7.5, driver 615.78) — NVENC exists but the footage kit's lossless 4:2:2 path is x264/CPU anyway. `hardware-configuration.nix` carries the patchelf-0.19.2 re-patch of the 615 driver's `bin/` (AGENTS.md "patchelf"); `nvidiaPackages.latest` + open modules. Plasma desktop; Sunshine runs as the cjdell **user** unit (`systemctl --user status sunshine`). `~/nixos-config` checkout here; root build key added to zen3 2026-11-03 (live when zen3 next switches). no autoRollback. |
| **hp-z240-xeon-1240v6-nixos** | `.59` (dnsmasq lease `3c:52:82:60:de:a9` live 2026-11-14; was dynamic `.156` only during install) | folding@home space heater (**second** HP Z240 SFF — Xeon E3-1240 v6 4c/8t, 8 GiB, **GTX 970 4GB**, which is also the only display output: this Xeon has no iGPU; Micron 2300 256G NVMe; Plasma console) | Adopted 2026-11-14 as a fresh `nixos-install` onto a blank NVMe from a live Ventoy stick, provisioned from zen3 (remote builder via the new host's root key + repo tar). **Since 2026-11-15 it has its own `~/nixos-config` clone**: bundle-cloned from zen3 over the LAN (the box has no GitHub key of its own), `origin` set to `git@github.com:cjdell/nixos-config.git`, so updates come via agent forwarding — `ssh -A cjdell@192.168.49.59 "cd nixos-config && git pull --ff-only"` (fetch verified; it sits `ahead 1` until zen3's 2026-11-15 commit is pushed). It evaluates its own system, offloads builds to zen3 (`/etc/nix/machines` is populated, and `nix build --max-jobs 0` really does pull from `ssh-ng://root@192.168.49.50`), and the rebuild is now run **on the box**: `sudo nixos-rebuild switch --flake .`. Name resurrected from the old Z240 host (that box's GPU workarounds died with its rebuild into asus-i7-6700); **different physical chassis** — this one's PCH xHCI works (verified at adoption: devices enumerate, no `-110`), so it carries **no `xhci_hcd.quirks` param**. Native fah-client (donor cjdell, team 236565, linked via the sops `fah_account_token`; fleet age key installed at `/var/lib/sops-nix/key.txt`): all 8 threads + the 970 on the OpenMM core via CUDA, **GPU hard-capped at 100 W** (see below), NVIDIA ICD env pattern copied from asus-i7-6700 (`OCL_ICD_VENDORS` at the driver's own ICD, `HOME` in a CacheDirectory). Driver pinned to `nvidiaPackages.legacy_580` (last Maxwell branch) **plus the patchelf-0.19.2 nvidia-smi re-patch** in `hardware-configuration.nix`. ⚠️ **THE 240 W SFF PSU BROWN-OUT SAGA — SOLVED, adoption day 2026-11-14** (full measurements in the file header): flat out it hard-reset at +101 s/+130 s (mid-line journal ends, no panic/MCE — same failure that derated the first Z240); the old boot-unit `nvidia-smi -pl` recipe STILL reset, because **the cap was being silently REVERTED to the 200 W unlocked-OEM-VBIOS default by the display stack after the boot unit ran** (persistence mode off) — the poller caught 187 W @ 99 % util under a "reported 100 W" limit; the first Z240's caps were likely theatre too. **The fix that holds**: `-pm 1` + `-pl 100` in **fah-client's own `ExecStartPre`** (`mkAfter`, i.e. seconds before folding starts, desktop long up) — verified enforced: 95–101 W at 100 % util, SM 822–899 MHz, throttle reason `0x4` SW Power Cap, stable 25+ min; `-lgc` clock-locking is unsupported on this VBIOS, so the cap IS the clock limiter. Fleet lesson: **verify a power cap under load** (`power.draw` + `clocks_throttle_reasons.active`, not `power.limit`). Config: `enableGpu=true`, `cpus=8`, `startDelay=90`, panel `budget=180`; if resets ever return, the header lists the escalation ladder. fah-panel gpu=nvidia on port 80 **with `cpuTempTarget = 80`** (zen1 convention; sliders are live-only — both the CPU-temp target and the GPU cap only exist across reboots because the config re-applies them), Web Control `:7396`. no autoRollback. |
| **asus-x555la-nixos** | `.70` (was dynamic `.152`; lease on the **Wi-Fi** MAC `40:e2:30:9e:9f:4a`) | e-waste **ASUS X555LA laptop** (2014), **adopted 2026-11-18 — no role yet** | i3-4030U Haswell 2c/4t, 11 GiB RAM, 120 GB KingDian S280 (107 GiB root, ~90 free), Intel HD 4400 (`i915`, H.264 VAAPI only — no HEVC, no useful Vulkan). Was hostname **`asus-haswell`** with a hand-written `/etc/nixos` on `nixos-26.05` and no entry anywhere in this repo (not `machines/*` either); its `~/nixos-config` was a plain copy, **not a git repo**. Now `hosts/asus-x555la-nixos` on the fleet pin, **live on it since 2026-11-18 12:26** (`readlink /run/current-system` → `hwjj7b9b…-nixos-system-asus-x555la-nixos-26.11.20261017.09063bd`); the hostname really is `asus-x555la-nixos` now, so expect a fresh host key. Still on dynamic `.152` until the router picks up the `.70` reservation below. Kept on purpose: a **minimal GNOME console** in host `desktop.nix` (not `common/gnome.nix` — that is the full alderlake workstation, several GB on this root), **NetworkManager** (the Wi-Fi PSK lives in `/etc/NetworkManager/system-connections`, which Nix does not manage — a networkd conversion means re-joining at the console), UUID mounts (its labels are `ESP`/`nixos`/`swap`, not the fleet's `BOOT`/`ROOT`), **no sops** (`users/cjdell/opencode.nix` degrades without the age key, as on rocketlakelatitude), **no autoRollback**. ✅ **THE ADOPTION-DAY CUT-OUTS WERE THE AC SUPPLY RUNNING UNDER-VOLTAGE — fixed by raising the PSU output, same day.** Nothing in NixOS was involved: the `26.05` AND `26.11` generations both died identically (~4 s, silent journal end, user saw "boot text then instant power off"), and the "new gen won't boot" story evaporated the moment the rail was corrected — it has been up since. Thermal is excluded too: 4 CPU spinners + 5 GB of `dd oflag=dsync` for 120 s gave **0 package-throttle events** and `x86_pkg_temp` peaking at only 45 °C. What the evidence actually looked like, and the lesson: **`Power-Off_Retract_Count 44`** on a 618 `Power_On_Hours` drive (`Power_Cycle_Count 756`) — a counter that only moves on unclean power loss — plus SMART otherwise clean (0 reallocated/pending/uncorrectable/CRC, 99 % lifetime). I nevertheless chased two wrong causes in one day, and the second mistake is the instructive one: after a correct first read of boot `-3` (ends at 02:56:33 mid-ssh with no `Suspending`/OOM/MCE — logind and gsd-power both **log** a suspend, so the silence was evidence *against* sleep), the single observation "it went to sleep" made me call sleep decisive and queue a kernel/systemd bisect. It was not: a black screen and a dead network are also exactly what an under-volted rail does, `asus_wmi: failed to register LPS0 sleep handler` meant this box can barely S3 at all, and **pstore is unavailable here** (`Platform Persistent Storage Archival skipped`) so a hardware stop leaves no trace — "nothing in the journal" proves nothing either way. **An anecdote about a symptom must not outrank a counter that only moves on unclean power loss; and do not bisect nixpkgs on a silent, log-less stop until the power path is excluded.** Raising the voltage is a *mitigation*, not a diagnosis of *why* it was low — a worn barrel jack, a tired brick or dead pack-detection all do this; the right fix is a proper **19 V / 2.37 A (45 W)** adapter, so until that is settled **do not trust this box with state that must survive a write**. `./power.nix` is prevention, not the fix: UPower sat at its distro default `CriticalPowerAction=HybridSleep` (`PercentageAction=2`, `UsePercentageForPolicy=true`) while the box reports a permanently `0%` / `0 Wh` / `pending-charge` pack — a loaded gun on a machine with **no remote wake path** (WoL off on ath9k, no cable, no serial, no BMC) — now `criticalPowerAction = "Ignore"` + `allowRiskyCriticalPowerAction` + `systemd.sleep.settings.Sleep.allow*=false` + `systemd.suppressedSystemUnits` + lid/power keys. **Verified functionally, not just written:** `systemctl start suspend.target` / `sleep.target` / `hibernate.target` all fail `Unit … not found` (rc 5) — the units a sleep request has to activate are absent from the generated set. ⚠️ Do NOT "verify" with `systemctl suspend`: it fails earlier, in polkit (`Call to Suspend failed: Access denied` from a non-session root caller), so it returns an error whether or not the sleep config is correct — a green result there proves nothing either way. (`sleep-actions.service` is still `enabled`; with no `sleep.target` it can never be pulled in.) ⚠️ **Three measured facts that rule out most e-waste-laptop jobs:** **both batteries are dead** (`energy-full: 0 Wh`) so there is **no UPS**, and the RTC coin cell is dead too (uptime read 6530 days after a clock jump), so **a mains outage resets the clock** — poison for snapshot naming, cert validity and any timestamped sync; **it is on Wi-Fi** (1x1 2.4 GHz `ath9k`: RTT avg 15.6 ms / max 137 ms / mdev 30.9 ms vs 0.62/0.90/0.22 ms wired N100-NAS, and two 32 MB incompressible copies did not finish in 90 s) while the **r8169 gigabit port has no cable** (`carrier=0`, MAC `f0:79:59:30:7b:42` — replace the lease line rather than adding a second, or the interfaces fight); the "VGA UVC" webcam is **640×480**, so not a Frigate camera. Useful physical assets: panel+keyboard+speakers (console/alarm surface), SD/MS card reader (`rtsx_usb`), DVD±RW, HDMI **out**, VT-x, 11 GiB RAM. Its 2c/4t makes it a poor F@H heater and a far worse LLM lane than zen3's RX 580 `lfm3` (no AVX-512). | Its **root build key now exists** (`/root/.ssh/id_ed25519`), authorized in `hosts/zen3-nixos/default.nix` — **pending zen3's next switch**, so until then its switches build locally on 2 cores. Because it had neither a root key nor nix trusted-user status, its closure could not use `nix copy`: the working pattern was build on zen3 → `nix-store -qR` vs the laptop's `ls /nix/store` (**`LC_ALL=C sort` both sides** — mismatched collation silently misreports paths as present) → `nix-store --export <delta>` piped through `zstd -T2 -3` into `ssh laptop 'cat > /tmp/x.zst'` → `zstd -t` → one sudo'd `nix-store --import` + `nix-env --profile /nix/var/nix/profiles/system --set` + `switch-to-configuration switch`. First adopt: 9.27 GB NAR → 3.32 GB compressed → ~20 min on the good AP; a config-only change after that was **6 paths / 105 KB**. ⚠️ `sudo` here needs a password (not in the repo — ask; it is a throwaway e-waste box, but a committed password is still a bad habit) and this NixOS has **no `/etc/sudoers.d`**, so the usual drop-in trick fails — do one authenticated `sudo` per privileged job. ⚠️ **`~/nixos-config` there has no way to fetch on its own**: the box has **no ssh private keys at all** (`~/.ssh` holds only `known_hosts`), so a plain `git fetch zen3` dies `Permission denied (publickey…)` and `origin` is equally unreachable — zen3→laptop ssh works (zen3's key is in its `authorized_keys`), the reverse does not. **The pattern that works is agent forwarding, verified:** `ssh -A cjdell@<laptop> "cd nixos-config && git fetch zen3 main && git merge --ff-only FETCH_HEAD"` — the laptop authenticates *back* to zen3 with zen3's own forwarded key (`98d5060` → `d626ddd`). Fallback if no agent is available: `git bundle create /tmp/x.bundle <old>..main` on zen3 → `scp` → `git fetch /tmp/x.bundle refs/heads/main` + `git merge --ff-only FETCH_HEAD`. Root **does** have `/root/.ssh/id_ed25519`, so once zen3's next switch authorizes it, root→zen3 fetches and `nix build --max-jobs 0` both start working. **It now sits on the `49 Grafton Street 2.4GHz` AP, not `The Lab 2.4GHz`** (moved 2026-11-18: signal 34→94, RTT 15.6→3.6 ms, 0.65→4.6 MB/s) — that join is **imperative NM state in `/etc/NetworkManager/system-connections`, the PSK is not in Nix**; declaring it needs a sops secret. `~/nixos-config` there is a **shallow** clone from zen3 (`.git/shallow` — `git fetch --unshallow` once it has working auth, i.e. after zen3's next switch) with remotes `zen3` (LAN) + `origin` (github); its old hand-written config is kept at `~/nixos-config.pre-adopt-2026-11-18`. |
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
  2026-10-25: haswellatx-nixos + hp-z240-xeon-1240v6-nixos (now
  **asus-i7-6700-nixos**); 2026-11-03: kabylakeitx-nixos; 2026-11-14:
  hp-z240-xeon-1240v6-nixos (second Z240, `.59`); 2026-11-18:
  asus-x555la-nixos (the e-waste X555LA laptop — **live only on zen3's next
  switch**, so its own switches build locally until then). **All the earlier
  ones are live since the 2026-11-15 zen3 switch** (11 declared keys then, all
  11 present — check with
  `sudo cut -d' ' -f2 /etc/ssh/authorized_keys.d/root`). Two traps when
  verifying this: NixOS writes `openssh.authorizedKeys.keys` to
  **`/etc/ssh/authorized_keys.d/<user>`**, not `~/.ssh/authorized_keys` (which
  is where hand-appends land and which a switch does NOT clean — zen3 still
  carries a stale imperative `.59` line there, harmless since sshd reads both),
  and `grep builders /etc/nix/nix.conf` proves nothing because
  `builders = @/etc/nix/machines` is nix's *default* — the real client-side
  check is `sudo cat /etc/nix/machines`. Also: a correctly onboarded client
  still builds small sequential chains locally (`max-jobs 1` covers them), so
  that is not the fallback symptom; ask the question directly with
  `sudo nix build --no-link --max-jobs 0 --substituters '' nixpkgs#hello`, where
  `copying path … from 'ssh-ng://root@192.168.49.50'` is the end-to-end proof.
  Still outstanding: rocketlakelatitude, 3d-printer-server, legacy
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
    `2a02:8010:6680:49::50` — an address in Zen's *delegated* /48, mirrored by
    a Route 53 AAAA record: if the delegation ever really changes (verify per
    `hosts/grafton-router/networking/constants.nix` — a WAN SLAAC /64 is NOT a
    delegation signal), this external record is part of the sweep list). The
    wildcard fallback vhost in
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

## stable-diffusion-cpp (Flux-schnell service + SDXL on disk)

`stable-diffusion-cpp` is installed on zen3-nixos as a **Vulkan build** — the
nixpkgs default is CPU-only (`SD_VULKAN=OFF`), so `hosts/zen3-nixos/ai/sd-server.nix`
uses `(stable-diffusion-cpp.override { vulkanSupport = true; })`. The binaries
are `sd-cli` and `sd-server` (upstream renamed from `sd`). **Since 2026-11-06
the service runs FLUX.1-schnell; SDXL remains on disk for ad-hoc `sd-cli` use.**

- Models live in `/home/cjdell/sd-models`: the Flux set (see the sd-server
  section) plus SDXL base fp16 (`sd_xl_base_1.0.safetensors`, 6.5G) +
  `clip_l.fp16.safetensors`, `clip_g.fp16.safetensors`,
  `sdxl_vae.fp16.safetensors` (from `stabilityai/stable-diffusion-xl-base-1.0`).
- Vulkan device numbering: sd-server.nix pins sd-server to the R9700 with the
  same device-select layer env (`MESA_VK_DEVICE_SELECT=1002:7551!`), so
  `vulkan0` = R9700 and the console GPU is not visible to it. Same for all
  three llama-swap routers (see the gotchas section).

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

### sd-server: Flux-schnell on stable-diffusion.cpp (started by `gpu-mode sd`)

**`sd-gate` was retired 2026-11-06 and SDXL replaced by FLUX.1-schnell**
(Apache, 4-step guidance-distilled, much better per watt). With `gpu-mode`
as this box's scheduler the gate's spawn-on-connection + 120 s idle-kill
automated something the lease now does by hand — and for an ~18 GB GGUF
set that reload-ping-pong would have been actively bad. What remains is a
plain unit, **`sd-server`** (`hosts/zen3-nixos/ai/sd-server.nix`): `sd-server`
on `127.0.0.1:8085`, **no `wantedBy`** — `gpu-mode sd` starts it and waits
until `GET /v1/models` answers (the model load is minutes on a cold page
cache), `gpu-mode llm|game` stops it. nginx `/sd-api` now proxies straight
to 8085 (was 8084 via the gate); **same URLs**, except the gate's
`/sd-status/` page is gone with it.

- **Weights** in `/home/cjdell/sd-models`, fetched by
  `scripts/fetch-flux-schnell.sh` (resumable, size+sha256 pinned):
  `flux1-schnell-Q8_0.gguf` (12.7 GB, city96/FLUX.1-schnell-gguf) +
  `t5xxl_fp8_e4m3fn_scaled.safetensors` + `clip_l.safetensors`
  (comfyanonymous/flux_text_encoders) + `ae.safetensors` (flux AE;
  camenduru/FLUX.1-dev mirror — BFL's own repo 401s unauthenticated).
  `ConditionPathExists` refuses to start the unit on an unprepared set.
- **The schnell recipe is baked into the unit**: `--guidance 1.0` (the
  3.5 default is FLUX-dev's distilled-guidance value), `--cfg-scale 1.0`
  (schnell needs no CFG branch), `--vae-tiling` (the flux AE decode hits
  the same RADV ~4 GiB allocation cap the SDXL VAE did), `--max-vram -1`,
  pinned by `MESA_VK_DEVICE_SELECT=1002:7551!` so `vulkan0` is the R9700.
  VRAM: ~12 GB DiT + ~5 GB t5 + graphs — comfortable with the LLM off lease.
- **Web UI:** `http://192.168.49.50/sd/` or `https://sd.ai.chrisdell.info/`
  (`sd-webui/`, copied into the store via `runCommandLocal`). Defaults are
  now the schnell recipe (steps 4 / cfg 1 / euler), the status pill says
  *server down — gpu-mode sd* when the unit is off (no more auto-wake), and
  the localStorage key moved to `-v2` so stale SDXL-era slider memory does
  not resurrect itself.
- **API:** `POST http://192.168.49.50/sd-api/sdapi/v1/txt2img` (full param
  control: steps/cfg/seed/sampler/negative_prompt), or
  `https://sd.ai.chrisdell.info/{sd-api,sdapi,v1}/…`; the OpenAI-style
  `/v1/images/generations` on this build still **ignores** steps/cfg/seed.
- **Strata's `before_load` hook stops `sd-server`** (`hosts/zen3-nixos/ai/strata.nix`)
  — the one lease-protection direction that survived the gate: an engine
  reload cannot land on a full card. The reverse (the gate's old
  `POST /v1/unload` eviction + auto-reload dance) is gone; the lease is
  unit state and `gpu-mode` is the only switch.
- **SDXL is still on disk** (8.2 GB total) for `sd-cli` experiments with the
  test command above; pointing the unit's model args back at it is a
  second-service change if it is ever wanted as a service again.

## GPU modes: `gpu-mode llm | sd | game` (zen3-nixos)

(The `llm` lease commands `strata.service` again since 2026-11-04, after the
same-day Avalon interlude — "ready" comes from Strata's `/v1/status`
`loaded:true`, and sd/game evict via `POST /v1/unload` + stopping
`strata.service`; if you ever flip back to Avalon, revert `gpu-mode.sh` from
git history too — it is engine-specific. See the Avalon section for that
lease's `/health` + `/slots` form.)

One 32 GiB card, three jobs that each want it whole: the Strata LLM, Stable
Diffusion, and (occasionally) a game. `gpu-mode`
(`hosts/zen3-nixos/ai/gpu-mode.nix` + `./gpu-mode.sh`, installed on PATH)
makes the card a **lease**:

- `gpu-mode` — status: which mode holds the card, per-unit state, whether
  Strata's model is loaded / flux is ready, what is in flight, MiB free.
- `gpu-mode llm` — stop `sd-server`, start `strata`, wait until `/v1/status`
  reports `loaded:true` (the model load is **multi-minute**, ~60 GiB RAM;
  the box is sluggish while it fills). **The boot default.** If the serve
  layer is already up but its engine was evicted, it sends a 1-token warm-up
  request so "ready" really means ready.
- `gpu-mode sd` — stop `strata`, wait for the VRAM, then start `sd-server`
  and wait until flux answers `GET /v1/models` (~18 GB; minutes on a cold
  page cache). It stays loaded for the whole lease — no idle-unload since
  sd-gate was retired 2026-11-06.
- `gpu-mode game` (aliases `free` / `off`) — stop both: 32 GiB of VRAM and
  the ~60 GiB of RAM Strata held come back. Polls `amd-smi` until free.

The lease is exclusive by *unit state*: sd/game **stop** `strata.service`
(not merely unload it), so background Pi/Recallium traffic cannot
auto-reload the 90 GB model into VRAM mid-game — the LLM endpoints answer
502 while off lease, which is the point. Interactive switches warn + confirm
if a Strata turn is in flight. A reboot always restores `llm`
(`sd-server.service` deliberately has no `wantedBy` — only `gpu-mode` starts
it). The one overlap that could still arise — `strata.service` started by
hand during an sd lease — is guarded by Strata's `before_load` hook, which
stops `sd-server` before the engine reloads. The script calls
`/run/wrappers/bin/sudo` (passwordless wheel on this host), so no polkit
rule is needed.

## LFM3-1.7B on the RX 580 (`lfm3.service` — the second-card lane)

`hosts/zen3-nixos/ai/lfm3.nix`: stock llama.cpp **Vulkan** (`llamaCppPkgs.vulkan`,
the flake's `llama-cpp` input — `a0677c34` (2026-11-23 HEAD, moved from
`956591f4` 2026-11-11 for Inkling-2-Mini's #32704 floor, see the Inkling
section; must stay ≥ upstream b11960 for lfm3) serving
`LFM3-1.7B-Q4_K_M.gguf` (from `scripts/fetch-lfm3-1.7b.sh`, rev+size+sha256 pinned)
on the **RX 580 = the console GPU** (`1002:67df`, renderD128). Loopback
`127.0.0.1:8086`; `lfm3.ai.chrisdell.info` (UI + API) and `/lfm3/` on the IP vhost.

- **Not part of the `gpu-mode` lease and cannot disturb Strata:** the unit pins
  `MESA_VK_DEVICE_SELECT=1002:67df!`, so the R9700 is *invisible* to it —
  verified: the process holds only renderD128, and `gpu-mode` still manages
  only strata + sd-server. Always on (`wantedBy`); a `nixos-rebuild switch`
  that touches nothing else does not restart `strata.service`.
- **The RX 580 is a 4 GiB card** (not 8 — llama.cpp reports 4096 MiB, ~3.6 GiB
  free under Plasma). `--ctx-size 131072` (raised from 32768 the same day):
  cost model from two measured points = ~1126 MiB fixed (weights+graphs, LFM3
  keeps KV on 11 of 24 layers) + ~12.99 KiB/token → 131072 sits at ~2.8 GiB,
  ~800 MiB slack. Hard ceiling ~185-190K — don't chase it (that slack is the
  GTT-spill insurance for the console GPU) and the full 262144 native window
  cannot fit. With `kv_unified` the pool commits once and the 4 llama-server
  slots share it — n_slots doesn't multiply KV memory. Real limit is prefill:
  ~90-220 tok/s, so a cold 131K prompt is a 10-25 min first token.
- Measured on Polaris (no coopmat): **76.9 tok/s decode, 87–223 tok/s
  prefill**, `n_slots 4` (llama-server default parallelism — unlike Strata's
  one-slot engine, concurrent small requests are fine here). ⚠️ LFM3 is a
  reasoning hybrid: it fills `reasoning_content` BEFORE `content`, so a small
  `max_tokens` yields a correct-looking `finish_reason: length` with EMPTY
  `content` (budget 240+ for one-line answers). gfx803 has no
  ROCm/HIP path; Vulkan/RADV it is (`WARNING: radv is not a conformant
  Vulkan implementation` in the log is normal).
- **Server-side tools are ON** (`--tools all`, since 2026-11-11): llama.cpp's
  built-ins (`read_file, file_glob_search, grep_search, exec_shell_command,
  write_file, edit_file, get_info`) run in llama.cpp's own sandbox —
  `--tools-runtime podman:docker.io/library/python:3.11-slim` keeps a
  `podman run --rm -i … sh` alive for the server's lifetime and routes every
  call through `podman exec`; verified the model cannot see `/home/cjdell`
  from inside. **Never drop the runtime flag on a reachable endpoint** —
  without it the tools execute as the service user (root). The unit needs
  `path = [ pkgs.podman ]` (NixOS gives units a minimal PATH and llama.cpp
  execs podman from it — missing podman = crash-loop `failed to spawn podman
  container`). Chat contract: `GET /tools` for schemas → chat returns
  `tool_calls` → caller executes via `POST /tools {"tool":…,"params":…}` →
  send result back; the Web UI does this loop itself. Because tools + public
  endpoint = an agent runtime for the anonymous internet, the
  `lfm3.ai.chrisdell.info` vhost is allow-listed to LAN/VLAN10/WG/tailnet +
  the LAN /64 + leighhack's `2001:8b0:1d14::/48` (`deny all`, hass-rs
  pattern); the IP vhost `/lfm3/` needs no list (RFC1918 = LAN-only). ⚠️ The
  llama.cpp Web UI shows a misleading "API key required" for ANY non-2xx
  `/props` response — if a legit client hits the deny rule, check
  `journalctl -u nginx | grep 'access forbidden'` before blaming auth
  (2026-11-11: user browsing from leighhack hit exactly this).
- **MCP: not wired.** llama.cpp's MCP client (#26062, `--mcp-servers-config`,
  Cursor JSON) is **stdio-only** — MCP servers spawn as child processes with
  the server's (root) privileges. Recallium/diamcp speak Streamable HTTP, so
  nothing connects without a stdio↔HTTP bridge; `--ui-mcp-proxy` is unrelated
  (it lets the *browser* UI reach remote MCPs).
- ⚠️ `nix flake update llama-cpp` does **not** rebuild Strata: strata-package.nix
  `fetchFromGitHub`s its own pinned llama.cpp `3cf03257` for `tools/vision`
  only, independent of this input. Bumping `llama-cpp` only moves llama-swap's
  (disabled) build, alderlake's, asus' and this service's next switch.

## Inkling-2-Mini on llama.cpp (`inkling-2-mini.service` — the third swap lane)

Thinking Machines' Inkling 2 Mini (released 2026-11-20, Apache 2.0), served by
**stock llama.cpp Vulkan** on the R9700 — Strata cannot run it: the engine's
families are qwen4exp/qwen35moe and `inkling2_loop` (a **looped** transformer:
24 physical layers, layers 6–17 run 3× = 48 layer-visits, 8-of-128 MoE, hybrid
local/global attention, per-expert NVFP4 scales) matches neither. It is a
strata-swap table entry, not a new proxy: `hosts/zen3-nixos/ai/inkling.nix`
publishes it via the new `ai.swapEngines` option (consumed in strata.nix's
`swapConfig`); `ai.strataEngineUnits` gains `inkling-2-mini` so `gpu-mode
sd|game` stops it and `gpu-mode llm` evicts it like the Strata partners. No
`wantedBy` — a reboot still serves `ai.strataModel`; a request naming
`inkling-2-mini-ud-q4_k_xl` on :8080 drains the live engine, swaps units, and
waits (same contract as coder/q36).

- **Run line** (all VRAM knobs documented in the module's header comment):
  UD-Q4_K_XL (17.63 GB, Unsloth's KLD plateau) **fully offloaded**,
  `-c 524288` (NOT the model's 1M: q8_0 KV ≈ 16.9 KB/token — only 8 of the 48
  expanded cache layers are global, window 1024 for the rest — so 512K ≈ 9.4 GB
  and the whole config stays under 32624 MiB **fully committed**; 1M would not),
  `-fa on`, `-ctk/-ctv q8_0`, `--parallel 1`, `-b 4096 -ub 1024`, `--jinja`,
  `--slots`, mmproj-F16 for vision, pinned `MESA_VK_DEVICE_SELECT=1002:7551!`,
  port 8094 (8091/8092/8093 are strata/coder/q36 — swapConfig asserts port
  uniqueness).
- **Files**: `scripts/fetch-inkling-2-mini.sh` (rev+size+sha pinned) — and it
  must fetch from **`Mainline_Support/`** (`inkling2_loop` tensor layout,
  renamed to `.gguf`): the repo's ROOT UD files use Unsloth's looped layout
  and mainline rejects them. **llama-cpp has two floors for this lane**:
  **b12611** (#32704, 2026-11-20) — older mainline loads the file but silently
  loses the per-expert NVFP4 scales on loop passes 2/3, ppl ~130 instead of
  7.65, no load-time error — and **#32735 (2026-11-22)**, which is what makes
  it usable at all: at b12611 Vulkan's `supports_op` rejects `SCALE` on
  non-contiguous input (`ggml_is_contiguous(op->src[0])` in the
  `GGML_OP_SCALE` arm), so SiTU's two scales per layer — applied to the strided
  gate/up halves of the fused `gate_up` — ran **on the CPU**, 194 graph splits
  per token, and decode sat at **20 t/s**. Upstream's own report is the same
  numbers on the same card (tg128 19.1 -> 53.8, pp512 507 -> 1605).
  `nix flake update llama-cpp` is now also what updates this lane (and
  lfm3/`asus`/`alderlake` at their next switches; the shared floor is the max
  of lfm3's b11960, this b12611 and #32735).
- **Measured on this box 2026-11-23** (`a0677c34` + the
  `GGML_VK_MAX_NODES_PER_SUBMIT=10000` env in `inkling.nix`): **decode
  20.1 -> 33.6 t/s** (llama-bench tg128 34.4 -> 35.7), **prefill pp512
  ~440 -> 1061 t/s** (an 800-token prompt ingests at 884 t/s), VRAM 31.1 ->
  29.7 GB of 32.6. What is left is dispatch-bound, not a knob: one decoded
  token is ~7,650 kernel launches and 66 % of the 36 ms step is ~3.6 us
  elementwise/copy kernels (SiTU's scale/sigmoid/sqr/sqrt/tanh + the loop's
  concat/cont/cpy/repeat, all separate dispatches) — matmul is 33 %. Fixes are
  upstream fusion (#32855, #32752 open). `-ub 2048` measures *worse* here
  (pp2048 999.7 -> 963.1; keep 1024) and RADV reports `fp4: 0`, so NVFP4 never
  gets the RDNA4 int8 coopmat MMQ (`if (!rdna4)` in `ggml_vulkan.cpp`). **That
  last theory was then A/B'd and did NOT hold**: `scripts/fetch-inkling-2-mini.sh
  --iq4xs` fetches Unsloth's UD-IQ4_XS (15.73 GB, KLD 0.0109 vs Q4_K_XL's
  0.0107 — the same plateau), and on this card the two are identical:
  **pp512 1066.8 vs 1065.6, pp2048 998.9 vs 996.1, tg128 35.69 vs 36.00–36.09,
  tg128 @32K depth 31.94 vs 32.25** (llama-bench, 2026-11-23). So the lane
  stays on UD-Q4_K_XL; IQ4_XS is only worth fetching if the 1.8 GiB of VRAM or
  the slightly smaller file is wanted.
- ⚠️ **A `nixos-rebuild switch` starts `strata.service` even while a partner
  engine is live** (strata is `wantedBy=multi-user.target` and the partner
  units have no `wantedBy`), so a switch quietly puts the 90 GB Flash-Next
  engine back on the card alongside Inkling. After any switch on zen3:
  `sudo systemctl stop strata && sudo systemctl start inkling-2-mini` — a
  measurement taken while strata is loading is garbage (a decode read 19.6
  t/s that way, vs 33.6 when quiet).
- ⚠️ **`llama-cpp` is pinned to `a0677c34` (2026-11-23) in `flake.nix`, not
  floating HEAD**: from ~2026-11-20 the upstream flake builds a new Svelte webui
  (`useWebUi ? true`), and that derivation fails in the sandbox
  (brand-favicons `copyfile` EACCES overwriting files in the read-only flake
  source — present at b12611 and at 2026-11-23 HEAD alike). `flake.nix`'s
  `llamaCppPkgs` wrapper now sets `.override { useWebUi = false; }` — which is
  what every llamaCppPkgs build here has always shipped (the classic UI is
  embedded in the binary; the old package had no webui reference). Moving to a
  newer llama.cpp = keep that override until upstream fixes the derivation,
  then restore the floating url and test-build (`#webui` is not a public flake
  output — test through the toplevel).
- **No speculation drafting**: DSpark (`--spec-type draft-dspark`) is still
  open PR #32218 on mainline (unsloth: ~1.1–1.2× when it lands, with the
  Mainline_Support drafter files); `--mtp` does not apply to this model at all.
- **Sampling**: model card = temp 1.0 / top-p 1.0 / top-k 0 / min-p 0 (also
  embedded in the GGUF as `general.sampling.*`); reasoning effort is
  per-request `chat_template_kwargs` (template default `high`). Known quirk
  from the card: it can loop in long reasoning — cap output tokens client-side.
- **strata-swap kinds**: the shim's table entries now carry `kind`
  (`"strata"` default, `"llama"`): liveness/drain via llama-server's `/slots`
  (answered only once the model is loaded; needs `--slots`) instead of
  `/v1/status`, and while a llama engine is live the shim **synthesizes**
  `/v1/status` so `gpu-mode.sh`'s `json_field` parsing keeps working
  unchanged. Name-blind traffic follows the live engine as always — while
  inkling is live, Recallium's nightly runs on inkling.

## opencode supervisor plugin (`users/cjdell/opencode/plugins/supervisor.ts`)

A plugin of the auto-context family that lets the **LFM3 lane police the
Strata lane**: it subscribes to opencode's thinking events and intervenes on
long-horizon agent runs so they finish unattended. Live since 2026-11-11.

- **Large-steps-only policy (user-set): a thinking step under 4000 chars
  (~1k tokens) is not supervised at all** — looping risk concentrates in
  steps that balloon; healthy reasoning runs 100–400 tokens. Kills false
  positives and CPU cost on normal reasoning.
- Three gates: **(1) token collapse** — the *live* `session.reasoning.delta`
  stream's unique-char-8-gram ratio drops below 0.01 → `session.interrupt` +
  steer prompt instantly (this is the strata `!`/`索` #606-class stream;
  measured: collapse 0.001 vs repetitive-but-legit 0.04 vs prose 0.98 — the
  0.01 line never fires on healthy output). **(2) verbatim loop** — ≥3
  consecutive similar (word-4gram Jaccard ≥0.6; measured near-dup 0.69,
  progressing 0.06) completed BIG steps → deterministic interrupt (the judge
  never gates this: 14 s of judging = more wasted generation). **(3)
  premature stop** — on `session.idle` read the last assistant message from
  `session.context` (deterministic when unambiguous: silent tool work / big
  think then empty / `rawFinish=length`; LFM3 judge when ambiguous) → queued
  nudge demanding a results report. Budgets: 4 loop + 3 stop nudges/h/session.
- **Judge lanes = fleet-wide, like Strata itself:** `http://127.0.0.1:8086`
  first (zen3), then `http://192.168.49.50/lfm3/v1` via nginx — so every LAN
  host running the plugin gets the identical full behaviour (off-LAN degrades
  to the deterministic gates; rotates lanes on failure, `LFM3_ENDPOINT` pins
  one).
- **Judge reliability: LFM3 JSON prompts need `max_tokens 1200`** — at
  ≤900 it dies `finish=length` with empty `content` (thinking eats it; the
  GGUF template has NO `thinking` kwarg so `thinking:false` is a no-op, and
  `response_format json_object` makes it worse). At 1200: ~14 s, `stop`,
  clean JSON (parse `content` first, `reasoning_content` fallback).
- **Ops traps learned:** opencode's background service has **stdout on
  /dev/null** → plugin logs must go to a file (this one appends
  `~/.local/share/opencode/supervisor.log` — the audit trail for every
  intervention); **v2.2.7 hot-reload re-runs the CACHED module** — plugin
  code changes land on the next service (re)start, so never restart it from
  inside an opencode session (that session dies with it);
  `session.message.content.updated` is in the v2.2.7 OpenAPI schemas but is
  **not a subscribable event type** (server warns and ignores it).

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
  (in `hosts/zen3-nixos/ai/recallium.nix`) → **`recallium-llm-shim` on
  `127.0.0.1:8090`** → **Strata on `127.0.0.1:8080/v1`** — the same upstream
  `https://strata.ai.chrisdell.info/` serves, hit on loopback instead of
  hairpinning TLS. The shim (`hosts/zen3-nixos/ai/recallium-llm-shim.py`,
  `recallium-llm-shim.service`) exists because Recallium asks for
  `max_tokens=2000` and Strata's `answer_room` spends 1488 of it thinking, so
  every insight answer came back truncated and `json_repair`-patched (25/25 on
  the 2026-11-17 nightly run, ~87 s each). The 2000 is compiled into the image
  (`PROTECTED_BUILD`), so the shim adds
  `chat_template_kwargs.enable_thinking=false` to `/chat/completions` bodies and
  streams the rest untouched. Switching backend = edit that one location block
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
- **Active model:** whatever the :8080 engine serves — Strata's
  `qwen3.8-flash-next-unsloth-ud-iq4-xs-v31` (renamed 2026-11-04 for the DFlash2
  name gate, `-v31` on 2026-11-05 with the Dynamic v3.1 pack; see the Strata
  section) via `config.ai.strataModel` again since
  2026-11-04 (the brief Avalon interlude served `--alias qwen3.8-flash-next`).
  Recallium's DB row still says
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

## Avalon (Qwen3.8-Flash-Next on the R9700 — DISABLED 2026-11-04, same day)

⚠️ **Rolled back to Strata on 2026-11-04.** Avalon ran on `:8080` for part of
that day; the flip-back is the import swap in `hosts/zen3-nixos/ai/default.nix`
(comment `./avalon.nix`, uncomment `./strata.nix`) **plus** restoring
`gpu-mode.sh` + `sd-server.nix` (formerly `sd-gate.nix`) to the matching era's version from git history —
the lease logic is engine-specific. Everything below stays as the deployment
record (it worked: 2,115 t/s prefill, 89 t/s decode, vision via mtmd) and the
rollback procedure.

**Avalon** (github.com/freriadoc/Avalon) replaced Strata on `127.0.0.1:8080`
on 2026-11-04 — deliberately, keeping **every client URL identical**: it is a
fork of llama.cpp tuned for exactly the one model this box serves
(Qwen3.8-Flash-Next, 512-expert MoE), with the experts hosted in system RAM,
a GPU expert cache prefilled from `moe-cache-ranking.bin`, MTP speculative
decoding from a shared draft head, and fused RDNA kernels. Same idea as
Strata, llama.cpp-native serve surface: no Python serve layer, no
hang-watchdog core dumps (docs/strata-hang.md), no ROCm-10 runtime override,
no #879 audit patch to re-base every release. Upstream numbers: 86.6 t/s on
an R9700 (user-reported) where their Strata showed 31 — our Strata measured
60-64 tok/s on the UD-IQ4_XS pack on 0.2.7.1, so Avalon's realistic win here
is prefill (~1,500-1,900 t/s vs our ~1,250) and long context. RDNA4 is
"reported working, not measured" upstream — treat the first days accordingly.

- **Flake:** input `avalon = github:freriadoc/Avalon` (nixpkgs follows ours).
  Its `.devops/nix/` tree is unmodified llama.cpp, so `nix build .#avalon` =
  `hosts/zen3-nixos/ai/avalon-package.nix` instantiating that scope with
  `useRocm = true`, `rocmGpuTargets = "gfx1201"` (nixpkgs ROCm 7.2.3 — clr
  lists gfx1201 and rocblas/hipblas build Tensile kernels for it; upstream
  tests on 7.2.4) and `LLAMA_BUILD_TESTS=OFF` (the llamaCppPkgs ICE reason).
- **Service `avalon.service`** (`hosts/zen3-nixos/ai/avalon.nix`): stock
  `llama-server` on `127.0.0.1:8080`, OpenAI-compatible; the run line is
  Avalon's documented `avalon-server` command (262144 ctx — Strata's
  393216-via-YaRN is NOT repeated, `-b/-ub 9536`, FA on, KV q8_0/q4_0,
  `--parallel 1`, MTP 2 drafts, `--fit` default) plus `--alias
  qwen3.8-flash-next`, `--slots` (gpu-mode's in-flight check),
  `--cache-reuse 256`, `-cram 16384` (**MiB** - 16 GiB cap on the RAM prompt
  cache, llama.cpp's units; the llama-swap-era `-cram 65536` = 64 GiB OOM'd
  this box) and `--log-prompts-dir llama-logs/`, which
  revives llama-log-viewer (dark since llama-swap stopped writing it).
- **Model data** lives OUT of the store:
  `/home/cjdell/Models/Qwen3.8-Flash-Next-Avalon-GGUF` (33 IQ3_KS-hybrid
  shards, `MTP/mtp-…FR65k.gguf`, `moe-cache-ranking.bin`, ~89.7 GiB) from
  `scripts/fetch-avalon-model.sh` (HF rev `372fe3a4e572c5ba75a90e579de0695633d083a8`
  pinned, per-file size + sha256, resumable; `--check` verifies). The unit's
  `ConditionPathExists` refuses to start an unprepared set. The IQ3_KS
  hybrid keeps ISTA's experts and re-quantises 27 layers' gate/up from the
  BF16 original with an imatrix: better perplexity than the IQ3_S Strata
  served, close to UD-IQ4_XS, at 89 instead of 93.7 GiB.
- **URLs are unchanged on purpose:** the `/` location on the `192.168.49.50`
  vhost, the `strata.ai.chrisdell.info` vhost (kept as the public name —
  same cert), `llm.`/`llama.ai` via `../tls.nix`'s wildcard fallback, and
  Recallium's `/recallium-llm/` all still proxy `127.0.0.1:8080`. llama.cpp's
  server ignores the requested `model` name (no 404 path), so Recallium's
  stale DB row and every client config keep working. `POST /v1/unload` and
  `/v1/status` are GONE (Strata-only endpoints): sd-gate's
  `--llm-unload-url` was dropped and `gpu-mode` now checks `/health`
  (200 = model resident) + `/slots`.
- **Lease differences vs the Strata era:** llama.cpp has no unload endpoint,
  so `gpu-mode sd|game` stopping `avalon.service` IS the eviction (an ad-hoc
  overlap runs SD at GTT-spill speed), and there is no auto-reload — after
  `gpu-mode llm` the unit loads the model before `/health` goes 200. Also
  parked for now:
  **multi-conversation KV parking** (a Strata feature; llama.cpp re-reads a
  switched-away prompt, softened by `--cache-reuse`/`-cram`), and
  >262144-ctx YaRN extrapolation. **Vision is ON since 2026-11-04:**
  `--mmproj /home/cjdell/Models/mmproj-Qwen3.8-Flash-Next-BF16.gguf
  --no-mmproj-offload` (the same ISTA `qwen3vl_merger` encoder Strata's
  strata-vision used; Avalon's fork carries `tools/mtmd/models/qwen3vl.cpp`,
  verified by a CPU-only `llama-mtmd-cli` load + red-PNG answer before
  enabling). The ~1 GiB encoder stays on CPU — the expert cache leaves ~100
  MiB of VRAM — encoding ~5 s/image. Deleting that file without removing the
  flag kills the service at load.
- **Rollback:** swap the `./avalon.nix` / `./strata.nix` imports in
  `hosts/zen3-nixos/ai/default.nix` — Strata's packs, config and
  `rocm10-runtime.nix` are untouched; importing both would double-bind
  :8080, so never enable them at once.

## Strata (Qwen3.8-Flash-Next on the R9700 — LIVE AGAIN since 2026-11-04)

⚠️ **Re-enabled 2026-11-04**, the same day the Avalon section above briefly
took over `:8080` and every nginx location this one owns. `./strata.nix` is
imported again (its packs, the ROCm-10 runtime input and the audit diff were
untouched throughout — `ai.strataModel` never moved off `ud-iq4-xs`);
flipping engines again = swap the `./strata.nix` / `./avalon.nix` imports in
`hosts/zen3-nixos/ai/default.nix` **and** restore the matching era's
`gpu-mode.sh` + `sd-server.nix` (formerly `sd-gate.nix`) from git history. Everything below is live
procedure plus the incident history.

The serving engine is **Strata** (a separate stack from llama.cpp), pinned at
**0.2.13.1+main-13eedf55** (tag `628f7495` + main `13eedf55`, engine **0.1.59.1**) —
**reverted back to it on 2026-11-20 16:24** after the **2026-11-20 prefill stalls**
hit 0.2.15 (engine 0.1.61) and 0.2.17 (engine 0.1.63). Full evidence pack, the
ruled-out table and a ready-to-file upstream report:
**`docs/strata-prefill-stall-2026-11-20.md`**.
The signature: `exit -6` from Strata's own 60 s no-progress watchdog (issue #29)
during a full re-read of a 148–289 K-token prompt, always at **layers 18–22**, while
the stall report says `the prompt's GPU work (GPU 0) was still running`, the host
thread is idle, the 15 CPU-pool workers are parked and 0 of 80 threads wait on disk —
with **no** amdgpu error (no ring timeout, no reset, no VM fault, no overdrive
failure). Sampled live during two hangs: **60–80 W, `gpu_busy 100`, `mem_busy 0`,
`mclk 1258`** (perf level `high` in one capture), i.e. a GPU kernel spinning with no
memory traffic — so the `mclk 96 MHz`/80 W state seen under `auto` is a *symptom* of
the spin, not a clock fault: it reproduced with `power_dpm_force_performance_level=high`
and survived a reboot. Synthetic repetitive prompts (99.8 % cache hit) never trip it;
real agent traffic does. Refuted one by one (all with a control run):
`STRATA_SELECT_WMMA=0`, `STRATA_PREFILL_ISSUER=0`, `--prompt-cache-every 0`,
`--conversation-cache-mib 0`, and the engine bump itself. 0.2.15's own release notes
list our hardware as KNOWN problems — *"Radeon gfx1201: DFlash2 chosen by hand can
stall on the prompt"* and *"Radeon R9700 on Linux: one engine start stalled on its
first prompt … stopped itself after 60 seconds without progress"*. Mitigations left in
place: **`STRATA_WATCHDOG_S=180`** (a stall that would have finished is not failed;
a truly stuck request holds the single slot 3 min) and the conversation cache **off**
(`--conversation-cache-mib 0`, since the failing requests were cache misses anyway).
**The 0.2.17 port exists and built** (commit `c905142`, engine 0.1.63, store
`ny7zm62zxg32s2psahv14cvyjdk6cp97-strata-0.2.17`) — keep the notes below if it is
re-tried:
**0.2.16 moved the tree into `engine/ app/ terminal/ tools/`, so the package differs
from the 0.2.13.1-era one:** `cmakeDir = "../engine"` (nixpkgs' cmake hook `cd`s into
`build/` first, so the path is relative to `build/`), the picture reader builds from
`terminal/tools/vision`, `serve/ data/ strata_cli/ strata_control/ tools/` are copied
from `terminal/` into `share/strata`, and **`-DSTRATA_PREFILL_MMQ` is gone** (upstream
ships `tools/check_no_mmq.py`; the prompt path is Strata's own kernels). Three
consequences: **`strata-kernel-audit.diff` is NOT applied** — it must be re-based onto
`engine/src/...` (audit only, everything behind `STRATA_KERNEL_AUDIT`; re-base before the
next #879 capture); **`--expert-profile` now names
`/home/cjdell/Strata/expert-profile.bin`** — 0.2.17 ships no profile in `terminal/data`,
but 0.1.63 still *hard-requires* a static one for the resident CPU-expert tier
(`--resident-budget-gib` asks for it; without one the engine exits 2 with
`--resident-cpu-experts requires --mmap-experts and a static --expert-profile`), so the
0.2.15 file (196 KB, 24576 ranked pairs — verified accepted) lives beside the pack;
regenerate it from our own traffic with `--expert-profile-save` (#477); and
**`STRATA_ROUTE_TAIL_SKIP=7` is still ON by default** on this path despite the 0.2.17
note ("off by default"), checked in the engine log — so answers did not move.
Second family live on the same engine: **Qwen3.6-35B-A3B** — see the
`qwen36-ud-q4-k-xl` bullet below. Previous pins: 0.2.15 (`c7757280`, 2026-11-16 →
11-20), main-13eedf55 (2026-11-13 → 11-18, engine 0.1.59.1) and the v0.2.13.1
release `628f7495` (2026-11-10; from 0.2.11
`c3b3f503` via 0.2.12 `146df3c4` — the engine went 0.1.57 → 0.1.58 → **0.1.59.1**
across those two, so that was a real engine bump, not a docs tag; the
`.1` tag itself is a Control-only Intel-Arc hotfix whose sole build-relevant line
is `project(strata VERSION …)`). 0.2.0 split the repo into
**app + Terminal + engine** — and 0.2.13 re-cut the engine build by backend
(`cmake/backends/{cpu,cuda,hip}.cmake`, `add_executable(strata)` now lives in
`cmake/strata_gpu_engine.cmake:483`) and **vendored the ggml it compiles into
`third_party/strata-ggml`**, so `strata-package.nix` no longer passes
`-DSTRATA_GGML_DIR` (verified with `diff -r`: every common source of llama.cpp
`3cf03257`'s `ggml/` is byte-identical there — only the two CMakeLists are trimmed,
plus Strata's own `ggml-cuda-tq/` folder; the `VERSION.txt` pin is the same commit).
Since v0.2.15 the picture reader builds from the vendored `tools/vision` (0.2.17
moved it to `terminal/tools/vision`, built from Strata's own tower — keep that note
for the port; on the current 0.2.13.1 build it is the `llama`-based `tools/vision`
again, so `strata-vision` is built with `LLAMA_DIR`, `strata --families` → `qwen4exp
qwen35moe`).
0.2.0's split also means `serve/server.py` imports the
Terminal's `strata_control/` + `strata_cli/` Python packages, which `installPhase`
therefore ships too (without them the service dies at import). Built and **live since
2026-11-20 16:24 (0.2.13.1+main-13eedf55)** — `ExecStart` names
`/nix/store/<hash>-strata-0.2.13.1+main-13eedf55` and `/v1/status` reports
`"engine": "0.1.59.1"`):
`hosts/zen3-nixos/ai/strata.nix` + `strata-package.nix` (imported by
`hosts/zen3-nixos/ai/default.nix`, gated on `config.ai.strata`), systemd unit
`strata`, OpenAI-compatible on `127.0.0.1:8080/v1`. Model
`qwen3.8-flash-next-unsloth-ud-iq4-xs-v31` — Unsloth's **Dynamic v3.1** re-cut of
UD-IQ4_XS, live since 2026-11-05 15:20 (see the pack bullet below; the old
three-shard UD-IQ4_XS and the GSQ-RCO IQ3_S GGUFs have been deleted, so the
`iq3s` / `ud-iq4-xs` entries in `models` are re-downloadable schema only). Docs:
[`docs/strata.md`](docs/strata.md).

**One request at a time** (`/v1/status` → `concurrency.serving: 1`): Strata's batching
(`"parallel"` / `--batch N`) is available but off by default — since 2026-11-10 toggled by
**`strata-batch on|off|status`** (PATH command; `/var/lib/strata/batch-mode` picks the run
config at every service start, absent/garbage = solo, survives reboot/`gpu-mode`/rebuilds).
Measured on 0.2.13.1 with it ON, then switched back off: slots cost **2.34 GiB** VRAM +
85 MiB×2 DFlash2 slot-drafters (`STRATA_BATCH_DF2` is the 0.2.13.1 default with our
explicit `--draft dflash2` — the October "slots lose the drafts" analysis is obsolete),
shrinking the expert cache 24.54→21.99 GiB (−10.3 %) plus ~10 GiB **pinned RAM**; a *lone*
stream in batch mode decodes **39.2 vs 56.9 tok/s (−31 %)**, and two concurrent streams
manage only 14.7–26.6 each — less aggregate than one solo stream. Lazy batching inside the
engine is impossible (slots are carved at startup, before the cache is sized, never handed
back); the toggle is the lazy version, outside it. Analysis + 2026-11-10 addendum:
[`docs/strata-batching.md`](docs/strata-batching.md).

⚠️ **The whole card is a lease, not an allocation:** `gpu-mode sd|game`
(see the GPU-modes section) **stops `strata.service` outright** — do not
"restart it for good measure" while testing SD or gaming, that reloads the
model and eats the VRAM for minutes. The serve layer's `POST /v1/unload`
(model leaves VRAM, auto-reloads on the next request) and the `before_load`
config key (a shell command run before every (re)load — ours stops
`sd-server`, the Flux unit; until 2026-11-06 it stopped `sd-gate`, and the
gate's reverse eviction over `/v1/unload` died with it) are what let the
two servers hand the card without fighting.

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

⚠️ **0.2.12 changes answers on our card too** — `STRATA_GDN_CHUNKED`, on by default for
gfx12: the **chunked GDN (gated-delta) scan** replaces the recurrent one on the prompt path
(upstream R9700: 32K +6.1 %, 64K +6.7 %; its "R9700 32K prompts +8.6–11.6 %" headline is
largely this). 0.2.12 gated it at chunks of 30,000+ tokens; **0.2.13 made it the engine's own
default and dropped the gate** — `generate.cpp:3821-3830` calls
`apply_gdn_chunked_default(true, all_gfx12)` ("Linux, every visible card gfx12: the chunked
GDN scan from the first chunk (was the launcher's GDN_STACK_GFX12)"), so here every prompt
chunk takes it. ⚠️ It leaves **no evidence in the log or the environment**: the engine
`setenv`s it in-process before `apply_arch_defaults`, which deliberately suppresses the
"prompt chunks of 30,000+ tokens use the chunked GDN scan" banner (upstream says so in that
block's comment), and a post-exec `setenv` is invisible in `/proc/<pid>/environ` anyway — the
only check is the A/B (`STRATA_GDN_CHUNKED=0`). Different kernel, so it is the first suspect
for "the model answered differently after 2026-11-10", at any depth (before this bump the
only answer-changing gfx12 default was `STRATA_SELECT_WMMA` above 28,672 tokens, and that
banner *does* print). The other 0.2.13 line that reads like it moves us does not: the
hipBLASLt tuning table stopped being applied on gfx1201 by default (`gemm.cu:319`), but our
build has never installed a `tuning/` folder next to the binary, so we have always been on
plain hipBLAS. Also from 0.2.12: **Auto no longer picks DFlash2 on gfx1201** (see the DFlash2
bullet), and 0.2.13 vendored the ggml (see the pin paragraph above). Measured on this box
after the 2026-11-10 deploy: **60–78 tok/s decode at ~200K context**, expert cache 95–98 %
hits, DFlash2 acceptance 74–76 % (0.2.11 measured 67.9 tok/s on the same traffic).

❌ **`STRATA_PF_FUSED_Q50` — measured on 2026-11-10 and left OFF** (it looks attractive because
`moe_fused_iq.cu:1940` names our pack: "Q5_0 down (UD-IQ4_XS-v31: 33 of 48 layers)", and
upstream's R9700 headline is prompts 2K +44 % / 8K +40 %; `=1` routes those layers' down
projection through the fused int8 prompt kernel instead of gather + FP16 dequantize +
hipBLASLt, prompt path only — it cannot blind the #879 audit, whose `native_expert_grouped`
probes are on the decode side, `verify.cpp:2375`). Local A/B, cold prompts, median tok/s:
**8.7K 2161 → 2672 (+24 %), 36K 2671 → 2804 (+5 %), 109K 3113 → 3293 (+5.8 %)**, decode
unchanged, a deep-needle retrieval probe correct in all 9 runs. It is not worth it because
**this box barely prefills**: across 58,154 logged requests the cold-read size is p50 223 /
p90 1.9K / p99 34K tokens (91 % under 4K — the 16 GiB conversation cache and KV reuse eat the
rest), so that curve is **0.08 s saved per request on average** (4,561 s off a 38,402 s
prefill lifetime, 670 requests saving >1 s). A permanent arithmetic change on 33 of 48 expert
layers per prompt is a bad trade for ~2–3 minutes a week, especially while #879 is open — we
want the prompt-path kernel mix unchanged when comparing a future capture. The A/B is one env
line, and `scripts/strata-pf-ab.sh` is the bench that made this call (cold prompts by a unique
first line, byte-identical per arm because the needle value derives from depth+rep, deep-needle
retrieval as the quality gate; it also works for `STRATA_SELECT_WMMA`, `STRATA_MMQ_KQ`,
`STRATA_PREFILL_CPU_SHARE`). One more reason it cannot pay here: reads at that size are
overhead-dominated — a 1.2K-token cold read runs at only ~670 tok/s, so at p50 the prefill is
almost entirely fixed cost.

- **DFlash2 is LIVE as the drafter since 2026-11-04** (`"drafting": "dflash2"` in
  `strata.nix`'s `configFile`): 0.2.10 made it the `auto` pick for Qwen3.8-Flash-Next on
  CUDA/HIP/Metal/SYCL — incoai's block drafter (packed from their pinned safetensors by
  `strata_control/drafting_fetch.ensure()`, pack sha checked against upstream's PINNED
  bytes), which serve's `drafting.apply()` starts **instead of** the MTP head (strips
  `--mtp`/`--spec-min-p`/our `--spec`, adds `--draft dflash2 --draft-model <pack>
  --draft-fallback none --spec N --draft-conf 0.5`; N is `SPEC_WINDOW` = **6 on
  0.2.10 through 0.2.13.1** (this file once said 8 — stale; the live `ExecStart`
  carries `--spec 6`), re-check per bump — `WIDE_WINDOW` 8 is reserved for
  `gfx1151`/big-Blackwell, so our gfx1201 keeps 6).
  ⚠️ **Since 0.2.12 that is an explicit choice, not the default:** upstream added
  `AUTO_MTP = {("hip","gfx1201"): "the DFlash2 prompt stall (11 of 50 engines on
  0.2.11); PE-RDNA4's fix is pending"}` — on an R9700, `auto` now starts the **MTP**,
  because "DFlash2 chosen by hand can stall on the prompt (11 of 50 engines on 0.2.11).
  The engine stops itself and the next request restarts it", still listed as **not
  looked at again in 0.2.13**. A saved `"drafting": "dflash2"` still starts DFlash2
  (upstream says so in that comment's own words), which is what we run: +2–2.5 % decode
  over MTP here, and no stall in the 6 days since 2026-11-04. So the failure mode to
  recognise is a prefill that never finishes and then the *next* request starts clean —
  it looks exactly like the #29 watchdog class in `docs/strata-hang.md`; check for it
  there before blaming KV streaming again. `"drafting": "mtp"` remains the one-line
  revert (and is what `auto` would now choose for us).
  The packs live in
  `/home/cjdell/Strata/dflash2/` (`data_dir` derives from our `--mtp` arg) — the
  **selq4** pack (339 MB, selector codebooks Q4_0, "about 174 MiB less") is the one
  `pack_path()` picks because our HIP engine reads it. Its pins are byte-identical
  from 0.2.10 through 0.2.13.1 (`CONVERTED_BYTES` 339,694,592 / sha `4a42b982…`,
  REPO/REVISION `a22a1744`), so a bump costs no re-download. Strata's **tuned**
  drafter (0.34 GB, `…strata1.q4_0-selq4.pack`, +2.4–5 % where measured) is new in
  0.2.12 and deliberately **not** ours: `SET_DEFAULTS ("hip","unsloth-ud-iq4_xs-v31")`
  is `tuned=True` but gated `where="gfx1151"`, `tuned_applies()` returns
  `arch == "gfx1151"`, and the table's comment says "NOT enabled: … gfx1201 / R9700
  (the DFlash2 prompt stall is open)" — so leave it alone until that stall is fixed. A/B on identical 700-token prompts
  (6+6 samples): **decode 60.6 vs 59.1 mean (+2–2.5 %, upstream claims +6.6/+4.2 on
  IQ3_S), draft acceptance 71–78 % vs MTP's 68.7 %, and expert slots UP 10608→10717** —
  the VRAM-contention worry never materialised, the selq4 drafter costs less than the MTP
  draft path it replaces; live agent traffic shows 95–98 % cache hits.
  ⚠️ **Name gate:** `drafting.py::_SUPPORTED_NAME` accepts only `qwen3.8-flash-next` +
  `-gyro-*`/`-unsloth-*`/a `(q|iq|tq)N` quant suffix, so the pack was renamed
  **`qwen3.8-flash-next-unsloth-ud-iq4-xs`** on 2026-11-04 (`modelName` in
  `strata.nix`; `...-v31` since 2026-11-05, which stays inside the `-unsloth-`
  class) — the old
  `...-ud-iq4-xs` shape silently answered `Drafting: MTP (DFlash2 is for
  Qwen3.8-Flash-Next only)`. The name is cosmetic at runtime (serve routes by engine) but
  `/v1/models` and `/metrics` echo it (and it is the id the `strata` provider in
  `users/cjdell/opencode.nix` declares), so **it must keep matching that regex on any
  future rename or Strata bump**. `--draft-fallback none` means a drafter that cannot
  start FAILS the service start rather than silently running MTP — if strata ever
  crash-loops on boot after a bump, `"drafting": "mtp"` is the one-line revert.
- **One pack live, two kept as schema: `config.ai.strataModel`** (`hosts/zen3-nixos/ai/default.nix`
  sets `"ud-iq4-xs-v31"`; the option default is `"iq3s"`). `hosts/zen3-nixos/ai/strata.nix`
  carries `models.iq3s` / `models.ud-iq4-xs` / `models.ud-iq4-xs-v31` (GGUF + pack
  paths, `--ple-gguf` only for the 2-shard pack, `--resident-budget-gib 55` for the
  old UD one and **`56` for v31** = setup.py's `int(arena_gb 60.4 / 1.0737)` cap).
  The live pack is Unsloth **UD-IQ4_XS "Dynamic v3.1"** (93.7 GB / **4 shards**, rev
  `d9620119…`, fetched by `scripts/fetch-strata-udiq4xs-v31.sh`, packed by
  `scripts/repack-strata-udiq4xs-v31.sh` — same **`--compat-bf16` REQUIRED** recipe;
  35 layers put gate/up/down in different shards, so `native_experts.txt` is the
  **v4 per-role** form and engine ≥ 0.1.57 is a hard requirement
  (`UNSLOTH_V31_ENGINE = (0, 1, 57)`, `setup.py:434` — still that value on 0.2.13.1,
  which builds 0.1.59.1). It is a different file from the October three-shard
  UD-IQ4_XS: 345 of 1224 tensors re-typed, 33 expert layers on the new Q5_0 down
  format, experts_bpw unchanged at 3.999 — so the old decode analysis applies
  (**60-64 tok/s at 92-94 % hits** on 0.2.7+; ~1,250 tok/s prefill; 393216 ctx).
  **Live since 2026-11-05 15:20**; the old three-shard GGUFs + `pack/ud-iq4-xs`
  and the GSQ-RCO IQ3_S GGUFs + `pack/iq3s` were deleted as it went live, so
  `"iq3s"`/`"ud-iq4-xs"` now only compile if you re-fetch first (their scripts
  stay). Analysis, quant mix and measurements: [`docs/strata.md`](docs/strata.md)
  "UD-IQ4_XS" + "Dynamic v3.1".
- **Second family, selectable since 2026-11-18: `models.qwen36-ud-q4-k-xl` —
  Qwen3.6-35B-A3B** ("the 35B a3b": 35B MoE / 3B active / 256 experts / top-8,
  arch `qwen35moe` — the code dir is src/qwen35/ and the engine file q36_engine.cu,
  which is why sources spell both 3.5 and 3.6; the catalog name is **3.6**, there is
  no Qwen3.5-35B-A3B entry). An **own-path engine**: reads ONE GGUF in place
  (`/home/cjdell/Models/Qwen3.6-35B-A3B-MTP-GGUF/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf`,
  22.85 GB, Unsloth's MTP-GGUF rev `5bc3e238…`, pins from setup.py's QWEN36_FILES —
  fetched by `scripts/fetch-strata-qwen36-35b-a3b.sh`), so **no iq_pack, no expert
  profile, no PLE shard, no `--resident-budget-gib`** — the engine places the
  experts itself, and drafting is the MTP block INSIDE the file: on this path
  `--mtp N` is a draft COUNT per step, not the Flash-Next draft-LAYER folder
  (doctor.py: "--mtp 2 is the draft depth, not a folder (#3298)"). The only
  hand-prepared part is the tokenizer pack (`tools/strata_tokenizer.py`, round-trip
  checked — `scripts/repack-strata-qwen36-35b-a3b.sh`, built 2026-11-18). Run line =
  setup.py's install_own_path step 7 verbatim: `--native <gguf> --max-context
  131072 --prefill auto --mtp 2`. **Why 128K, and why solo:** own_path_fit costs
  KV at 47,104 B/token (fp32 of the 10 attention layers + MTP, plus the engine's
  full-context fp16 K/V — `--kv int8` does NOT exist here) and 128K is what keeps
  every expert in the R9700's VRAM at this quant; upstream's measurement ON THIS
  CARD: "a 32 GB R9700 at 128K: 4 slots left 15 of 256 experts per layer, decode
  81 tok/s against ~180" — so the entry runs no `parallel` and `configFileBatch`
  carries `parallel = 1` for this family (strata-batch on|off stays a valid
  command, it just changes nothing), and expected solo decode is **~180 tok/s**
  vs Flash-Next's 60-78, at 128K-not-384K context and a 4x smaller model. The
  config JSON gains `arch = "qwen35moe"` (serve's FAMILY_MODEL_NAMES gate) and
  deliberately NO `drafting` key — the DFlash2 gate is Qwen3.8-only and
  drafting.supported_model() skips other families by design; a stray key could
  reshape the run line, and on this path that breaks the `--mtp` count. Vision:
  `mmproj-F16.gguf` (same qwen3vl_merger family, the CPU-reader rationale
  unchanged). `model_name` must keep the `qwen3.6-35b-a3b-ud-q4_k_xl` shape
  (own_path_fit parses the size back out of it). Serving it needs the 0.2.15
  engine (`--families` → `qwen4exp qwen35moe`); switching = one
  `ai.strataModel` line + rebuild + restart, same ConditionPathExists contract.
- **Third Flash-Next pack, selectable since 2026-11-22: `models.coder-iq1m` —
  Qwen3.8-Flash-Next Coder** (`ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-Coder-GGUF`,
  rev `5348543e…`, IQ1_M, 58.4 GB in two shards — shard 2 is the SAME PLE
  table, sha `316b46f3…`): ISTA's expert-pruned coder, **256 of the 512
  experts per layer kept** (code/tools/vision ones), stored like IQ3_S at
  3.5 bpw — "IQ1_M" is the file's average bpw, not a tensor type, so no new
  kernels and no engine floor past MIN_ENGINE (the pinned 0.1.59.1 reads it).
  setup.py: "needs ~32 GB of RAM, faster; weaker outside coding" — arena 23.4
  GB, so every expert is RAM-resident **without** `--resident-budget-gib`.
  Two things made it not a copy-paste entry: it ships its **own expert
  profile** (`expert-profile-coder.bin` in the package, 12,288 pairs — half
  the ranking; `models.<k>.profile` selects it via `expertProfileFor`), and
  **DFlash2 must NOT be configured for it** — `drafting.py`
  `SUPPORTED_FAMILIES = qwen/gyro/unsloth`: "Coder … no DFlash2 acceptance
  numbers for them, they start the MTP" — so the entry sets `dflash2 = false`
  and its config carries no `drafting` key; the shared
  `/home/cjdell/Strata/mtp/rt` runtime drafts it like the IQ3_S era.
  `selectable = true` puts it in the swap table under id
  **`qwen3.8-flash-next-coder-iq1m`** (upstream's own spelling is `…iq1_m`;
  nothing parses the tail — DFlash2 rejects both alike). Prepare with
  `scripts/fetch-strata-coder-iq1m.sh` + `scripts/repack-strata-coder-iq1m.sh`
  (plain `iq_pack.py`, NO `--compat-bf16` — that flag is for Unsloth files'
  Q8_0 dense side; the MTP runtime and mmproj are the ones already on disk).
- **Model choice via the API — `strata-swap`, live on `:8080` since 2026-11-18.**
  The engine is still one-model-per-process; what changed is the front.
  `strata-swap.py` (system unit `strata-swap`, root because it drives
  `systemctl`, loopback-only) owns **127.0.0.1:8080 — which every nginx
  location already proxied — so no client URL changed**; the engines moved
  behind it (primary `strata.service` → `:8091`; since 2026-11-22 one unit
  per **selectable** model instead of the old single `strata-second`:
  `strata-<key>.service` → `:8092+` in attr-name order, for every `models`
  entry marked `selectable = true` other than `config.ai.strataModel` — today
  `strata-coder-iq1m` (8092) and `strata-qwen36-ud-q4-k-xl` (8093), all built
  by the same `finalize (runConfigBaseFor mm …)` path so no config can
  drift; the 11-22 refactor left the primary's exec + run-config
  byte-identical to the live system). Its contract (full rationale in the
  file header — the shim was already table-driven, so the generalization cost
  it zero code):
  `GET /v1/models` advertises **every selectable** id (the non-live ones
  listed `"unloaded"` — serve's own loads-on-use form); a request whose
  `model` **exactly** names a non-live engine triggers a SWAP — **wait for the
  live engine's `activity.in_flight` to drain** (up to `SWAP_DRAIN_SECS`,
  default 180 s; still busy → 409 `busy`, **nothing stopped**) → stop live
  unit → wait
  `amd-smi` free VRAM (`vram_min_mib`: flash-next + coder 30000 / q36 25000;
  NOTE the
  amd-smi 7.2.4 `metric -m --json` shape is `gpu_data[0].mem_usage.free_vram`,
  not a flat list — the flat read silently returned None = gate skipped until
  fixed the same day) → `systemctl start strata-<key>` → poll `/v1/status`
  `loaded:true` (≤25 min,
  inside nginx's 3600 s location timeout) → forward the buffered request. A
  failed bring-up **rolls the stopped unit back** and 503s; with nothing live
  the shim **never starts an engine** (503 `gpu-mode llm`) — the lease
  invariant stays gpu-mode's. Unknown/absent `model` = untouched pass-through
  to whatever is live, which is what keeps Recallium's stale DB row and every
  name-blind client on the live model. A **liveness completion** (answer
  budget ≤ `SWAP_PROBE_MAX_TOKENS`=4 **and** ≤ `SWAP_PROBE_MAX_CHARS`=1024
  chars of message text, no tools) is likewise forwarded to the live engine
  even when it names another model — "are you still there" gets a *nod*, never
  a reload (2026-11-23: two clients naming different models had been turning
  every turn into a ~30 s reload and every reload into a SIGTERM'd request;
  the drain + nod are the fix, both logged as `WAIT`/`BUSY`/`NOD`). Consequences to remember: the first
  request after a name change pays the model load (measured 2026-11-18, warm
  page cache: flash→q36 26 s, q36→flash 45 s; cold cache = minutes — the shim
  waits `loaded:true` up to 25 min); a swap interrupts
  the other model's in-flight streams (journal line `SWAP <id> -> <id>`);
  name-blind traffic follows whichever model is live — llama-swap-era
  semantics, back with a Nix-built table (`swapConfig`) over the selectable
  models. `gpu-mode llm` restores the **primary** and stops every running
  partner first (warning + prompt if a turn is in flight);
  `gpu-mode sd|game` stop ALL LLM units — the list is
  `config.ai.strataEngineUnits` (primary first), baked into the command by
  `gpu-mode.nix` as `GPU_MODE_LLM_UNITS`, so a new selectable model needs no
  gpu-mode edit; a reboot always comes back on
  `ai.strataModel` (only `strata.service` has wantedBy). `strata-batch` still
  means flash-next-batching; on the ownPath partner the batch2 config is
  `parallel = 1`, a documented no-op.
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
  `prefill/kernels.cu:2558` (was 2509 in 0.2.11, 2257 in 0.2.7.1, 2199 in 0.2.1.1, 1702 in 0.1.44.1, 1691 in 0.1.43, 1340 in 0.1.42) — both
  live here because we run `--kv int8`. Still unclamped on 0.2.13.1 (re-checked on
  `628f7495`: `kv_q8.cu:55` has not moved and that file still contains no `65504` at all,
  and the prefill target is still exactly once — `hf_sat` now sits at `:69` above it), so
  both `postPatch` clamps are still needed and both
  `--replace-fail` targets are still unique.
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
  `HSA_USERPTR_FOR_PAGED_MEM=0` (upstream #750 = two R9700s on ROCm 7.2; the build-time
  nixpkgs ROCm moved 7.2.3 → 7.2.4 with the 0.2.13.1 deploy, but that scope is headers and
  link libs only — the engine maps its whole HIP runtime from `rocm10-runtime.nix`, proof:
  `sudo cat /proc/$(pgrep -f '[b]in/strata --serve')/maps | grep -c rocm10-runtime`) is
  applied in `configFile`'s `env` since 2026-10-08 — verify with
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
  onto 0.2.10 on 2026-11-04: **3 of 19 hunks were rejected** by upstream context changes
  and re-placed by hand (all three pure context shifts: a `strata::dispatch::notef()`
  inserted between the `hits_in_combine` compute and `moe_hit_add`; the `tap_on_` gate
  widened to `(!batch_rec_ || tap_batch_)` for DFlash2; and `native_expert_set_expdec`
  growing a tri-state `on < 0` — the trailing context line of the iq_kernels.cu hunk).
  The other 16 landed with offsets only. Regenerated from the patched tree: 19 hunks,
  280 additions, 0 deletions, byte-identical added lines, `--fuzz=0` with **no offsets**
  (`patch -p1 --fuzz=0` and `git apply --check` both clean). Re-based onto **0.2.11** on
  2026-11-05 with **zero rejects**: the file regenerated from the patched tree is the
  0.2.10 one with byte-identical added lines and only 4 hunk headers moved — a pure
  **+3-line drift in `src/kernels/cuda/iq_kernels.cu`** (the `native_expert_grouped`
  region). Re-based onto **0.2.13.1** on 2026-11-10, again with **zero rejects and no
  hand-placed hunks**: 19 hunks, 280 additions, byte-identical added lines, `patch -p1
  --fuzz=0` with no offsets and `git apply --check` clean on `628f7495`; the drift is
  `verify.cpp` +3 (two hunks +4, the `run()`-tail dump +10), `verify.hpp` +19 and three
  of `iq_kernels.cu`'s four hunks +7 — and that +7 is the whole file's diff between
  0.2.11 and 0.2.13.1 (the `STRATA_EXPERT_V2K` block at `:6306-6326` gaining Windows
  gfx1151), which is why hunk #1 did not move. Two clean re-bases in a row: the next
  bump is again an offset check first, a hand-place only if `iq_kernels.cu` or
  `verify.cpp` actually changes under the anchors. (Earlier re-bases: onto
  0.2.7.1 on 2026-10-29, 6 hand-placed — `topk_scratch_` in verify.hpp, the `sh_fork`
  `note_prio_tail` body, the `grouped()` trailing `true` + `ar_on()` branch (never live
  at our 43 % cache), the `tap_on_` block after `stamp(l, 24`, `tap_write`/
  STRATA_LOGITS_DUMP at the run()-tail dump site, the `g_exp_phase == 3` early-return;
  onto 0.2.1.1 on 2026-10-20, 5 hunks.)
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
Since 2026-11-19 there is an **IPv6** path through this VM — as of
2026-11-23 only for the **tailnet-only ULA**: `networking/interface.nix` routes
`fd99:dead:beef::/48` via the VM's link-local, while the hackspace's **public**
`2001:8b0:1d14::/48` now goes straight over Zen. Their nginx `…225::1` is
publicly routable and leigh keeps a standing firewall allow for the Grafton
IPv6 ranges; the via-VM route for the /48 was **deleted** because `gw`↔VM
tunnel flaps stall *established* TCP (SYN-ACK fine, data silent) — the one
failure browsers never fall back from: that was the 2026-11-22/23 "Pixel hangs,
then Mac hangs unless IPv4 forced" saga, and the old claim that forwarded v6
was masqueraded to the VM's fd7a address was false (masq rule counter 0 — LAN
clients crossed the tailnet with their own `2a02:…` source). The health check's
v6 layers now report HTTP 403 on `*.int` as "**their** allow row broke", and a
reappearing `ip -6 route show 2001:8b0:1d14::/48` means someone re-attached
the probe to the tunnel's flaps. Both directions of the history (the 794×403
of 2026-11-19 and this) are in `docs/leighhack-tailscale.md` — read it before
re-routing or re-pinning anything against that /48.

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

## patchelf 0.19.2 breaks NVIDIA and CUDA binaries (current pin)

The pinned nixpkgs (`26.11.20261017.09063bd`) ships **patchelf 0.19.2**, which
mangles NVIDIA's prebuilt binaries (NixOS/patchelf#674, NixOS/nixpkgs#576412).
Two unrelated-looking symptoms, both worked around locally — delete both
workarounds once nixpkgs ships the patchelf fix.

- **`nvidia-smi` (and `nvidia-cuda-mps-*`, `nvidia-debugdump`, `nvidia-powerd`)
  segfaults.** nvidia-x11's builder makes one combined
  `patchelf --interpreter … --set-rpath …` call (`builder.sh:203`); the result
  has overlapping LOAD segments with `.dynamic` mapped read-only, so ld.so dies
  with SEGV_ACCERR in `dl_main` before loading any library. The kernel modules
  and the libraries are fine — CUDA, OpenCL and the FAH container all keep
  working while the CLI tools are dead. Tell it apart from a real driver
  problem: a *healthy* `nvidia-smi` on a machine with no NVIDIA driver prints
  "couldn't communicate with the NVIDIA driver" (exit 9); the patchelf one
  dumps core even on zen3, which is AMD — that is the test to run before
  blaming the GPU. Fix: re-patch from the pristine copies the builder keeps in
  `$bin/origBin/`, **rpath first, interpreter second** — carried in
  `hosts/asus-i7-6700-nixos/hardware-configuration.nix` (its `legacy_580` pin)
  and `hosts/kabylakeitx-nixos/hardware-configuration.nix` (`latest`).
- **The merged CUDA set cannot be built at all.** `cudaPackages.cudatoolkit`
  *is* `cuda-merged`, and several of its components trip the same patchelf bug
  inside `autoAddDriverRunpath` —
  `Assertion 'splitIndex == -1' failed` on `compute-sanitizer/TreeLauncherSubreaper`
  and on `cuda-gdbserver` (`cuda_sanitizer_api`, `cuda_gdb`) — which takes the
  whole merged set down with it and makes **any system path containing CUDA**
  unbuildable. No substitute on the cache either: Hydra fails identically, so
  the first sign is a rebuild suddenly trying to compile 70+ CUDA derivations
  and then failing. `common/sunshine-nvidia.nix` therefore no longer puts
  `cudatoolkit` in `environment.systemPackages` (Sunshine needs exactly
  `cuda_nvcc` + `cuda_cudart` at build time and nothing at runtime). If a host
  really wants the toolkit, the hook has a per-component opt-out — re-scope
  with `pkgs.cudaPackages.overrideScope (f: p: { cuda_gdb =
  p.cuda_gdb.overrideAttrs (_: { dontUseAutoAddDriverRunpath = true; }); … })`
  for each component that trips it — but expect more than the two named here,
  and prefer `nix shell` over the system path.

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
- **Watchers must be kill-proof by construction: log marker, not `systemctl`.**
  Remote-state polling (`ssh host 'systemctl is-active X'`) is the unreliable
  half: under heavy NFS/disk load `systemctl` wedges on its dbus round-trip
  and the ssh probe times out, while plain file reads on the same host keep
  working. So an `is-active` watcher cannot distinguish "still running" from
  "signal lost", and an error-tolerating clause (`|| st=ssh-error` + continue)
  turns a lost signal into an infinite "running": the Dell-tape stitch watcher
  on kabylakeitx (2026-11-06) watched a finished job for 3 h 40 m past its
  last poll, and the TUI's terminate did not reap it. The rules:
  1. **Key completion on the job's own log**, written by the wrapper script
     itself (a terminal `DONE`/`FAIL` line), and `grep` for it via ssh —
     a file read that survives exactly the load that kills `systemctl`.
  2. **Budget by wall-clock, not just iterations**: `deadline=$(( $(date +%s)
     + expected_secs * 3 / 2 + 1800 ))` and break on it, so a wrong poll
     interval can never stretch the watch. Every watcher prints a terminal
     line (`DONE|FAIL|LOST-SIGNAL|DEADLINE`) and exits — no exit path is a bug.
  3. **Watchers only observe; the systemd unit owns all cleanup** (restart
     F@H, confirm, etc. inside the unit script) so killing a watcher mid-watch
     must always be safe.
- **Reaping a wedged background shell when the UI kill fails**: find the group
  and signal it — `ps -eo pid,pgid,etime,args | grep "[u]nique-watch-word"`,
  then `kill -KILL -<PGID>` (negative = whole group, takes the child `ssh`/
  `sleep` with it). OpenCode then marks the shell completed ("Killed by
  SIGTERM"). Watch the pattern bracket so the `grep`/`ps` cannot match its
  own command line.
- **Never pipe a whole capture file through a byte-level tool.** A 5.7 GB `.mpg`
  is ~17 GB of hex text, and `od -An -tx1 -v FILE | tr ' ' '\n' | awk '{a[NR]=$2}'`
  holds one array element per byte: it reached 7 GB RSS / 15 GB virtual on this
  7.7 GB laptop, ate all 9.2 GB of swap and froze the desktop for four minutes
  until the OOM killer picked it (2026-11-02, `awk` pid 61629; nothing else was
  killed). Read a bounded window instead -
  `dd bs=1M count=2 iflag=skip_bytes skip=<offset> if=FILE | od -tx1` -
  and ask first whether the check is even needed: in that case the answer had
  already been proved by two encodes of the same source in the same container
  reporting different field orders, which can only come from the bitstream.
- Do not run heavy builds unless the task requires it; the user applies Nix
  config themselves when they prefer.
- If you DO apply a config (with permission), always finish with
  `sudo nixos-confirm` on autoRollback hosts.
- The repo often has uncommitted/staged changes (e.g. `hosts/zen3-nixos/ai/`,
  `default.nix`)
  plus untracked scratch files (`dump.txt`, `logs.txt`, `ppp.sh`, `result*`).
  Leave them alone unless the task is about them.
