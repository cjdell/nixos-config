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
| `docs/recallium.md` | How to use the Recallium memory server (APIs, MCP, examples) |
| `docs/gtt-vram.md` | GTT-default/VRAM-cache research: `GGML_VK_ALLOW_SYSMEM_FALLBACK`, why there's no weight cache in llama.cpp, and why GTT never auto-unspills |
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
sudo nixos-rebuild boot   --impure --flake .
sudo nixos-rebuild switch --impure --flake .
```

- `--impure` is required (config reads the live system, e.g. UIDs).
- **alderlake-thinkpad builds exclusively on zen3-nixos** (`192.168.49.50`):
  `nix.distributedBuilds` + `nix.buildMachines` write `/etc/nix/machines`
  (Nix's default `builders = @/etc/nix/machines` picks it up) and
  `nix.settings.max-jobs = 0` disables local builds, so the daemon schedules
  up to 16 parallel jobs on the remote. Do **not** pass `--max-jobs` there —
  it overrides the config and serializes remote builds to one at a time.
- **If zen3-nixos is down**, the Thinkpad can still build locally: pass
  `--max-jobs 4` (root is a trusted user, so the flag overrides the daemon's
  `max-jobs = 0`), or temporarily set `nix.settings.max-jobs = 4` in
  `hosts/alderlake-thinkpad/default.nix`. Without an override, `nixos-rebuild`
  fails outright because local builds are disabled.
- Hosts *without* a build machine can still append `--max-jobs 1` to keep
  builds light on limited-RAM targets; the whole flake evaluates all ~20 hosts
  either way.
- Always follow with `sudo nixos-confirm` on hosts that enable autoRollback
  (see above).
- Avoid running `nix build`/`nixos-rebuild` for heavy jobs unless the task
  calls for it; the user often deploys manually.

## The live target host: `zen3-nixos`

This is the machine the repo lives on (`192.168.49.50`). It runs:

- **llama-server** via `llama-swap` on `127.0.0.1:8081` (model serving). Two
  llama.cpp router instances, one per GPU (see `hosts/zen3-nixos/ai.nix`),
  kept co-resident by a llama-swap `matrix` so neither evicts the other:
  `r9700` (Radeon R9700 32 GB, Vulkan0, `--models-max 1` = one resident model,
  no GTT spill) and `vega` (Vega 8 iGPU, Vulkan1, GTT-backed, up to 4 small
  models). Both run `-cram 8192`: idle-slot KV cache in system RAM, restored to
  VRAM on matching prompt prefixes (verified on Vulkan).
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

## stable-diffusion-cpp (SDXL on the R9700)

`stable-diffusion-cpp` is installed on zen3-nixos as a **Vulkan build** — the
nixpkgs default is CPU-only (`SD_VULKAN=OFF`), so `hosts/zen3-nixos/ai.nix`
uses `(stable-diffusion-cpp.override { vulkanSupport = true; })`. The binaries
are `sd-cli` and `sd-server` (upstream renamed from `sd`).

- Models live in `/home/cjdell/sd-models`: SDXL base fp16
  (`sd_xl_base_1.0.safetensors`, 6.5G) + `clip_l.fp16.safetensors`,
  `clip_g.fp16.safetensors`, `sdxl_vae.fp16.safetensors` (from
  `stabilityai/stable-diffusion-xl-base-1.0`).
- Vulkan device numbering matches llama.cpp: `vulkan0` = R9700, `vulkan1` =
  Vega iGPU.

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

- **systemd service `sd-gate`** (`hosts/zen3-nixos/ai.nix`; zero-dep Rust app
  in `sd-gate/`): always listens on `127.0.0.1:8084` (nginx's `/sd-api`
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
- **Status page:** `http://192.168.49.50/sd-status/` (JSON at
  `/sd-status/status`) — state, sd-server pid/times, idle-unload countdown,
  VRAM, and **active clients** (remote IP from nginx's `X-Forwarded-For`,
  request, age, phase): the reason the model is running and not shut down.
  Served by the gate on `127.0.0.1:8086`; the status listener never spawns
  the server.
- **Web UI:** `http://192.168.49.50/sd/` (static files in `sd-webui/`,
  copied into the store via `runCommandLocal` so nginx can serve them). The
  UI pings `/sd-api/v1/models` on load and every 30 s (2 s while the server
  is down/loading, status pill shows “loading model…”), so opening the page
  wakes the model and a closed tab lets it idle-unload after ~2 min.
- **API:** `http://192.168.49.50/sd-api/…` proxies to 8084 (the gate; it
  forwards to 8085, spawning sd-server if needed) with the `/sd-api` prefix
  stripped. The UI uses the A1111-style `POST /sd-api/sdapi/v1/txt2img` (full
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
memory server for AI agents: MCP + web UI + Postgres. Its LLM processing runs
on the **local llama.cpp via the ollama-bridge** (no cloud). Full usage docs:
`docs/recallium.md`.

- **UI:** `http://192.168.49.50:9001` or `http://192.168.49.50/recallium/`
- **MCP:** `http://192.168.49.50/recallium-mcp` (Streamable HTTP, protocol 2025-11-25)
- **REST:** `http://127.0.0.1:8001/api/...`; Postgres on `127.0.0.1:5433`
  (user `recallium` / `recallium_password`, db `recallium_memories`)
- **Chain:** container → `ollama-bridge` (`:11434`, systemd) → llama-swap
  `/upstream/r9700/v1` (the R9700 router; Recallium's coding model lives
  there) → llama.cpp. Container reaches the host via
  `host.containers.internal:11434`.
- **Active model:** `Qwen3-Coder-REAP-25B-A3B-Rust-Q4_K_M` (config id 7,
  `llm_provider_configs`). Model names are GGUF basenames auto-loaded by
  llama-swap from `/home/cjdell/Models`.

Operational essentials:

- `POST /api/memories/` **always returns 500** (upstream response-schema bug) —
  the row is still created; read it back via `GET /api/memories/{id}`.
- There is **no API to change the LLM model** — edit `llm_provider_configs` in
  Postgres directly, then `sudo podman restart recallium` (see docs/recallium.md
  for the exact SQL).
- **Zombie generations:** if a model is slow/looping, Recallium's 120 s client
  timeout disconnects but llama.cpp keeps generating forever. Kill with
  `curl -X POST http://127.0.0.1:8081/api/models/unload` (or `/unload/<name>`).
- `LFM2.5-2.6B-Q8_0` PGLoops on Recallium's JSON metadata prompt (see the
  llama-swap UI at `http://192.168.49.50/ui/#/logs`); don't switch it back.
- Setup is complete (`active_llm_config_id: 7`); `mcp_tools_enabled: false` in
  `/api/setup/status` is cosmetic and does not block MCP.

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

- Do not run heavy builds unless the task requires it; the user applies Nix
  config themselves when they prefer.
- If you DO apply a config (with permission), always finish with
  `sudo nixos-confirm` on autoRollback hosts.
- The repo often has uncommitted/staged changes (e.g. `ai.nix`, `default.nix`)
  plus untracked scratch files (`dump.txt`, `logs.txt`, `ppp.sh`, `result*`).
  Leave them alone unless the task is about them.
