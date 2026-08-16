# LiteLLM proxy on zen3-nixos

One OpenAI-compatible endpoint in front of every local LLM, so agents don't
care which model (or which GPU/box) actually serves them. **Date:** 2026-08-15.

## Endpoints

| URL | What |
| --- | --- |
| `http://192.168.49.50:4000` | litellm direct (LAN-reachable; firewall is off) |
| `http://192.168.49.50/v1` | same API via nginx (port 80) |
| `http://192.168.49.50/health` | litellm health (`/health/liveliness`, `/health/readiness`) |
| `http://192.168.49.50:8080` | Open WebUI chat UI (over litellm; first visit creates the admin account) |

Auth: `Authorization: Bearer <master_key>` (see `general_settings.master_key`
in `hosts/zen3-nixos/litellm.yaml`).

## Model groups ("LLM classes")

Clients request a **group name**, litellm routes to a concrete deployment:

| Group | Deployments (GGUF in `/home/cjdell/Models`) | Use for |
| --- | --- | --- |
| `scouting` | `ornith-1.0-9b-Q4_K_M` (one deployment — see residency note; `neutrino-8b-fv5` excluded, unreadable quant) | cheap fast passes, exploration, summaries |
| `planning` | `Qwen3.6-35B-A3B-UD-Q3_K_XL` | deep multi-step reasoning |
| `coding` | `Qwen3-Coder-REAP-25B-A3B-Rust-Q4_K_M` | code (Recallium's active model) |
| `creative` | `Qwen3.6-27B-Fable-Fus-711-...-Q4_K_M` | prose / roleplay |
| `uncensored` | `Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-Q4_K_M` | unfiltered (delete if unwanted) |

Every deployment points at llama-swap's Vulkan router
(`http://127.0.0.1:8081/upstream/vulkan/v1`) and names the model by its GGUF
basename; llama-server (`--models-dir`) loads it on demand, one model at a time
per GPU.

## Quick test

```sh
curl http://127.0.0.1:4000/v1/chat/completions \
  -H "Authorization: Bearer $(grep master_key hosts/zen3-nixos/litellm.yaml | awk '{print $2}')" \
  -H "Content-Type: application/json" \
  -d '{"model":"scouting","messages":[{"role":"user","content":"Say hi"}]}'

curl http://127.0.0.1:4000/v1/models -H "Authorization: Bearer $(...)"   # lists the groups
```

Agents on other boxes: point them at `http://192.168.49.50:4000` (base URL,
OpenAI-compatible) with the master key. If an agent hardcodes vendor model
names (`gpt-4o`, `claude-...`), add a `model_group_alias` entry in
`litellm.yaml`.

## Open WebUI (chat UI)

`hosts/zen3-nixos/open-webui.nix` enables the nixpkgs `services.open-webui`
module and points it at litellm (`OPENAI_API_BASE_URLS=http://127.0.0.1:4000/v1`
with the master key; Ollama disabled). Use it to sanity-check the groups from
a browser.

- URL: `http://192.168.49.50:8080` — **first visit creates the admin account**
  (auth is on; users/chats live in `/var/lib/open-webui`).
- It is **not** nginx-proxied: open-webui's frontend uses absolute API paths
  (`/api`, `/static`), so prefix proxying (like `/recallium/`) would break it.
- The package is not in the binary cache, so the first rebuild compiles it
  (~564 MiB download + the npm frontend build; 10-25 min, one-time).

## Model residency & swapping (single GPU)

llama-swap runs one llama-server per loaded model; with the current single
`vulkan` router entry that means **one model resident at a time**. A request
for a different GGUF triggers a **swap** (kill + reload; 10-60 s for the big
models, plus full KV allocation for the 262K ctx) while other requests queue
FIFO. llama.cpp also serves one request at a time (`-np 1`), so there is no
true concurrency on this box today.

Rules of thumb:

- **One litellm deployment per group** until deployments point at *different*
  backends (a second GPU entry, another box). Two deployments on the same
  llama-swap router just make litellm bounce between models = swap thrash.
- **Alternating groups cost a swap** per switch. Agents that interleave
  scouting and planning should be told to batch per group, or the combo should
  be kept co-resident (below).
- **Co-residency is configurable**: llama-swap v224 (this host) ships a routing
  engine — top-level `groups`, or the `matrix` solver (either, not both).
  `groups` with `swap: false` keeps its members loaded together, e.g. a `hot`
  group of `ornith + Qwen3.6-35B-A3B-UD-Q3_K_XL + Qwen3-Coder-REAP` (~40-60 GB
  GTT resident — each 262K-ctx model pays its full KV cache up front; measure
  with `free -g`). Ungrouped models (the long-tail router, Laguna) keep
  singleton behaviour and evict the group when loaded. `matrix` adds
  `evict_costs`/`sets` so the solver keeps the expensive models and evicts the
  cheap ones when memory needs making.
- `hooks.on_startup.preload` warms the combo at boot; per-model `ttl` (e.g.
  900 s) reclaims memory from idle residents. llama-swap supports
  `-watch-config` to reload config changes without a service restart.
- **RTX 2060 era**: a second llama-swap entry pinned to the NVIDIA device
  (`GGML_VK_VISIBLE_DEVICES`) gives real parallel inference (draft/scout on
  RTX, big MoE on Vega) — that's when multi-deployment litellm groups and
  `least-busy` start paying off. See `docs/multi-gpu-inference.md` Plan 3.

## Adding things

**A new model to an existing group** — add one deployment to `model_list` in
`hosts/zen3-nixos/litellm.yaml`, then:

```sh
sudo systemctl restart litellm
```

No Nix rebuild needed — the unit reads the file directly from the repo. The
model name must be the GGUF basename without `.gguf`.

**A new class/group** — same, but with a fresh `model_name`. Give agents the
group name.

**A second GPU on this box** (see `docs/multi-gpu-inference.md` Plan 3) — add
a new llama-swap model entry (e.g. `rtx` running the small model on the RTX),
then add a deployment per group pointing at
`http://127.0.0.1:8081/upstream/rtx/v1`. litellm load-balances (`least-busy`)
and fails over across the deployments in a group.

**Another box** — same pattern with a remote `api_base`:
`http://<box>:<port>/upstream/<entry>/v1` (or its own litellm).

## Notes & gotchas

- `drop_params: true` is set: llama.cpp rejects OpenAI params it doesn't know,
  litellm silently drops them instead of 400ing.
- `request_timeout: 1200` — the first request to a model pays its load time
  (17 GB models take a while); llama-swap swaps models for concurrent requests
  to different groups, so requests may queue.
- The master key is plaintext in `litellm.yaml` (this host has no sops, same
  as `DB_PASSWORD`/`VAULT_PASSPHRASE` in `ai.nix`). Rotate it if needed.
- `LFM2.5-2.6B-Q8_0` is deliberately **not** in any group (PGLoops on JSON
  prompts — see AGENTS.md).
- Multi-file GGUFs (e.g. `Laguna-S-2.1-UD-IQ4_NL`) aren't mapped yet; their
  router naming differs, and the ROCm cmd is commented out in `ai.nix`.
- Recallium still uses the Ollama API via `ollama-bridge` (port 11434) — litellm
  doesn't speak Ollama's API, so they coexist. New agents should use litellm.
- Debug: `journalctl -u litellm -f`. The CLI is on PATH
  (`litellm --config hosts/zen3-nixos/litellm.yaml --port 4001`) for
  experimenting without touching the running service.
