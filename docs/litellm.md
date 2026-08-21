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

Every deployment points at one of llama-swap's two per-GPU routers
(`http://127.0.0.1:8081/upstream/vega/v1` and `.../r9700/v1`) and names the
model by its GGUF basename; llama-server (`--models-dir`) loads it on demand
(scouting → Vega, everything else → R9700).

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

## Model residency & swapping (two GPUs, since the R9700)

Each GPU runs its own llama.cpp router instance (`llama-server --models-dir`),
spawned by llama-swap as the `r9700` and `vega` entries (`hosts/zen3-nixos/ai.nix`):

| llama-swap entry | GPU | Resident models | litellm groups |
| --- | --- | --- | --- |
| `r9700` | Radeon R9700 32 GB (Vulkan0) | `--models-max 1` | planning, coding, creative, uncensored |
| `vega` | Vega 8 iGPU (Vulkan1, GTT) | `--models-max 4` | scouting |

- **R9700 keeps ONE model resident at a time.** The router unloads the current
  model (waiting for the unload to finish) before loading the next, so weights
  + KV never spill into GTT — the 15-21 GB models can't share 32 GB. A request
  for a different big model still costs a swap (kill + reload + KV
  re-allocation), so agents should batch per group when alternating.
- **The Vega is GTT-backed** (512 MB real + ~90 GB GTT over system RAM), so
  overflow there is harmless; up to 4 small models stay resident. The research
  sub-agent's `scouting` group never touches the R9700.
- **True cross-GPU concurrency:** e.g. Recallium's `coding` chat on the R9700
  while a scouting pass runs on the Vega.
- **The two routers are kept co-resident via llama-swap's `matrix`** (set
  `gpus: "r & v"` in `hosts/zen3-nixos/ai.nix`). Without it llama-swap only
  runs **one model at a time** and would kill the other GPU's router on every
  request (verified live 2026-08-16: with no matrix, requesting `r9700`
  evicted the running `vega` router). Within each GPU, llama.cpp's router
  (`--models-max`) owns which GGUFs stay loaded.

## Context persistence: KV cache in system RAM

The RAM prompt cache (`-cram`) is the warm-start mechanism for agentic
workloads: idle-slot KV is saved to system RAM and restored to VRAM on the next
request with a matching prompt prefix (`--cache-idle-slots` is enabled by
default when `-cram` is set). **Verified on the Vulkan backend (2026-08-16):** a
1243-token prompt restored ~1240 of its tokens from RAM and evaluated only the
new tail — 16.4 s → 1.9 s per request.

Current values (2026-08-21):

- **r9700: `-cram 65536` + `--cache-reuse 256`** — the 32 GiB cap was observed
  MAXED by the pi-ai harness (llama-server RSS ~26.5 GiB, LRU evicting warm
  agent contexts), so it's doubled to 64 GiB: ~13 × 100k-token contexts stay
  warm at q8_0 (vs ~6). LRU + the bad_alloc fallback (limit auto-shrinks to
  40 %) bound the risk.
- **vega: `-cram 32768` + `--cache-reuse 256`** — its cache rarely fills
  (small models, small per-token KV).
- **`--cache-reuse 256`** (both) enables KV-shifting chunk reuse: runs of
  ≥256 tokens found in a new prompt at a *shifted* position (rolling-window
  contexts that trim history from the front, reordered segments) get shifted
  into place instead of re-evaluated. Auto-disabled with a warning on contexts
  that can't shift (SWA/hybrid/recurrent).

Implications for agentic workflows:

- Several sub-agents sharing the R9700 keep their contexts warm in RAM between
  turns (unified KV pool, idle slots cached); returning to a conversation does
  not re-evaluate the whole history.
- The RAM cache dies with the model process, so it does **not** survive a model
  swap (the R9700's `--models-max 1` unloads the current model when a different
  one is requested) or a server restart.
- `--slot-save-path` (explicit disk save/restore of a slot's KV via
  `POST /slots/{id}?action=save` / `restore` with `{"filename": ...}`) restores
  KV across restarts (1243 tokens in ~12 ms in testing), but this build still
  forces a full re-process of the next OpenAI-style request ("lack of cache
data"), so it buys nothing yet for the stateless chat API. Revisit when
  upstream wires restored KV into prompt reuse.
- Tuning gotcha: `-cram -1` removes the *MiB* cap, but the per-cache **token**
  cap (= `--ctx-size`, 320K on the r9700) still binds — that's ~15.7 GiB of
  REAP q8_0 states, SMALLER than the explicit 64 GiB cap. Keep an explicit MiB
  value; `--cache-reuse N` lowers/raises the minimum chunk size for the
  KV-shift path (default 0 = disabled).

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

**A second GPU on this box** — done: the R9700 replaced the planned RTX (see
`docs/multi-gpu-inference.md` Plan 3, now implemented as the `r9700` + `vega`
llama-swap entries). Adding another deployment to a group now means a *second
backend for the same group*, e.g. a second `scouting` deployment on another
box. litellm load-balances (`least-busy`) and fails over across the
deployments in a group.

**Another box** — same pattern with a remote `api_base`:
`http://<box>:<port>/upstream/<entry>/v1` (or its own litellm).

## Notes & gotchas

- `drop_params: true` is set: llama.cpp rejects OpenAI params it doesn't know,
  litellm silently drops them instead of 400ing.
- `request_timeout: 1200` — the first request to a model pays its load time
  (17 GB models take a while); the R9700 router unloads/reloads models for
  concurrent requests to different big-model groups, so requests may queue.
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
