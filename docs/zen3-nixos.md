> Archived from AGENTS.md (2026-11-24). The short version lives in AGENTS.md; this file holds the full backstory.

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

