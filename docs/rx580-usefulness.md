# RX580 usefulness report

Status: investigation complete; Recallium offload deployed and validated live
Date: 2026-08-23

## TL;DR

The RX 580 4 GB is **genuinely useful** in this system, but only for what it is:
a bandwidth-constrained secondary GPU for **small models (≤ ~4B)**. We proved it
end-to-end by moving Recallium's LLM processing onto it (Qwen3-4B-Instruct-2507
Q4_K_M), which freed ~30 GB of VRAM on the R9700 — the primary win. The card's
real bottlenecks turned out to be (a) the **128K-context KV cache spilling ~9 GB
into GTT**, and (b) the fact that it sits on a **PCIe 1.0 x2 link (0.5 GB/s)** —
decode is partly PCIe-bound. A physical slot swap would fix (b) but cripple the
R9700 (its slot is only wired x2), so the right fix is software: shrink the KV
so it fits in VRAM.

---

## 1. Hardware & system context

| GPU | PCIe addr | Slot / path | Link (measured) | VRAM | Role |
| --- | --- | --- | --- | --- | --- |
| R9700 (Navi 48) | `03:00.0` | CPU root port (primary x16) | **PCIe 4.0 x16 = 32 GB/s** | 32 GB | Big models (27B/25B), SDXL via sd-gate |
| RX 580 (Polaris) | `06:00.0` | chipset bridge `05:00.0` (wired **x2**) | **PCIe 1.0 x2 = 0.5 GB/s** | 4 GB | Small models, now Recallium |
| Vega 8 (Cezanne iGPU) | `0a:00.0` | on-die | PCIe 3.0 x16 | 0.5 GB (GTT-backed) | Small research models, display |

Board: Gigabyte B550 AORUS ELITE V2 (AM4, Cezanne APU). All three GPUs run
separate llama.cpp router instances under llama-swap (`llamaCmdR9700/Vega/Rx580`
in `hosts/zen3-nixos/ai.nix`), sharing `/home/cjdell/Models`; each is pinned to
its physical GPU by vendor/device ID (`MESA_VK_DEVICE_SELECT=1002:67df!` for the
RX580).

## 2. What the RX580 is actually asked to do

**Recallium's LLM workload is a single small strict-JSON metadata prompt**
(~700 input / ~250 output tokens), not LLM function-calling. Trace of
`llama-logs/` shows 81 instances of one prompt family ("You are a metadata
generator…"). The "tool calls" in Recallium are its MCP tools, invoked by the
*agent*, not by the LLM. So the bar for a Recallium model is simply: **emit
valid JSON reliably**. (The MCP tools are always available to clients
regardless of the LLM.)

The RX580 router also serves ad-hoc small-model requests from anything that
asks for a ≤4 GB model via `/upstream/rx580/v1`.

## 3. Measured performance (production router, not standalone)

| Model | Prefill | Decode | Notes |
| --- | --- | --- | --- |
| LFM2.5-2.6B-Q8_0 | 53–58 tok/s | **32 tok/s** | consistent across 6+ fresh-prompt runs |
| Qwen3-4B-Instruct-2507 Q4_K_M | ~0.4 s warm (system prompt KV-cached) | **15 tok/s** | 7–13 s per Recallium memory |

Cold first request loads the 2.5 GB model in ~5 s (page-cache warm). The
~600-token system prompt is KV-cached after the first call (`-cram`), so
subsequent memory processings prefill only the ~70-token user content.

### End-to-end Recallium validation (live, real traffic)

- Batch of **10/10 varied memory contents → 10/10 valid JSON** (correct schema,
  sensible summaries/tags).
- **5/5 real memories processed to `complete`** with proper
  `**Decision:**`/`**Bug:**`/`**Learning:**` headers.
- First call `llm_enrichment` 34.4 s (incl. model load); steady-state ~10–14 s
  per memory — far under Recallium's 120 s client timeout.
- R9700 VRAM went **30.7 GB → 0.1 GB** after switching Recallium to the RX580
  (its 27B was unloaded at the llama-swap restart and nothing reloaded it).

## 4. Model selection (the 4 GB constraint)

| Model | Size | Verdict |
| --- | --- | --- |
| LFM2.5-2.6B (Q4/Q6/Q8) | 1.6–2.7 GB | Fits, but **PGLoops on Recallium's metadata prompt** (see memory 1012). No. |
| **Qwen3-4B-Instruct-2507 (Q4_K_M)** | **2.5 GB** | **The choice.** Best-in-class 4B for JSON/instruction-following; validated 10/10 + 5/5. |
| Qwen3-8B-Q8_0, ornith-9B, DeepSeek-9B | 5.3–8.2 GB | Don't fit. |

Everything else in `/home/cjdell/Models` is ≥5.3 GB — the RX580 is a 4B-class
card, period.

## 5. The KV cache / GTT finding

Qwen3-4B geometry (read from GGUF header): 36 layers × 8 KV heads × 128 dim →
**76.5 KiB/token** at q8_0. The rx580 router runs `--ctx-size 131072` →
**9.6 GiB** of KV cache, pre-allocated at model load.

- VRAM can hold only the 2.5 GB weights + compute buffers (4.08/4.29 GB used);
  the KV (~9.6 GiB) is placed in **GTT** (GPU-visible system RAM) — measured
  **8.8–9.2 GB GTT** with the model loaded, 20 MB after unload. The child
  process's host RSS is only 481 MB, confirming the KV is device memory, not
  malloc.
- Attention reads GTT KV over PCIe on every decode token → at 0.5 GB/s,
  ~50 MB/token of GTT reads ≈ 100 ms/token, the same order as the measured
  66 ms/token decode. **The RX580's decode is substantially PCIe-bound.**
- This is expected spill behavior, not a leak: the actual used context is
  ~700 tokens ≈ 53 MB, and the hot KV sits in the VRAM-resident fraction.

## 6. PCIe analysis (why a slot swap is a bad idea)

- The RX580's slot is electrically **x2** (bridge `05:00.0` LnkCap = x2) and
  trains at **Gen1 x2 (0.5 GB/s)** even under load. On this board the chipset
  slot shares lanes with M.2B (the Micron P2/P3 at `07:00.0` is populated) —
  almost certainly the cause.
- A physical swap would give the RX580 the CPU slot (Gen3 x16 = 16 GB/s,
  Polaris max) — a 32× gain — **but** the R9700 would land in the x2 slot
  (Gen3 x2 = 2 GB/s max), a 16× cut on the primary GPU:
  - 18 GB model loads: 0.6 s → ~9 s
  - sd-gate churn (SDXL 6.5 GB + LLM reloads) much slower
  - large-context KV spill reads (pi agents run ~100K-token contexts) 16× slower
- **Recommendation: don't swap.** Fix the RX580 in software instead (see §8).

## 7. Implementation (final state: GPU switch is Nix-declarative)

1. Downloaded `Qwen3-4B-Instruct-2507-Q4_K_M.gguf` (2.5 GB) → `/home/cjdell/Models/`.
2. Restarted `llama-swap` — routers hold a **static model list from startup**,
   so new GGUFs require a restart (models unload and reload on demand).
3. SQL (one transaction, via `podman exec -i`):
   - `llm_provider_accounts` id 3 (openai) `base_url` →
     `http://host.containers.internal/recallium-llm` (the stable nginx proxy)
   - inserted `llm_models` id **1006** (Qwen3-4B under the openai provider)
   - `llm_provider_configs` id **1002** → model 1006, `is_active=true` (old
     config 1004 deactivated)
   - `llm_failover_priority` row repointed at config 1002
4. Restarted the `recallium` container.
5. `ai.nix`: added the **`recalliumGpu`** binding (currently `rx580`) and an
   nginx location `/recallium-llm/` that rewrites the prefix away and proxies
   to `http://127.0.0.1:8081/upstream/${recalliumGpu}/v1`. Switching GPUs is
   now: edit `recalliumGpu` (`rx580` | `r9700` | `vega`) + `nixos-rebuild
   switch` (+ `sudo nixos-confirm`). No DB edits, no container restart.

`active_llm_config_id` is now **1002** (was 1004 = Qwen3.8-27B on ollama/r9700).

### No bridge needed

Recallium has a first-class **OpenAI provider with a `base_url` override**
(`llm_provider_accounts.base_url`) — the container talks straight to the
stable nginx proxy `/recallium-llm`, which forwards to llama-swap's OpenAI API
(`/upstream/rx580/v1/chat/completions`). The `ollama-bridge` service (port
11434) is out of the Recallium path entirely; it still runs but nothing uses
it. It can be retired if nothing else consumes `:11434`.

### Gotcha: how `active_llm_config_id` is resolved

The setup status reads the **first active row of `llm_failover_priority`** —
not `llm_provider_configs.is_active`. Changing `is_active` alone does not
switch Recallium's model; you must repoint/insert the failover row too.

## 8. Recommendations

1. **Keep Recallium on the RX580** (Qwen3-4B). The 27B→4B quality drop is real
   but the metadata task is well within the 4B's ability; monitor for
   edge cases (long/non-English content, truncation).
2. **Do not swap GPU slots.** Reclaim the RX580's lanes instead:
   - (free) Move the M.2B NVMe to the CPU M.2A slot to restore the chipset
     slot to Gen3 x4 (4 GB/s, 8× current); reseat / force Gen3 in BIOS for
     even Gen3 x2 (2 GB/s, 4×).
3. **The real fix: shrink the rx580 router's KV so it fits in VRAM.** Change
   `--ctx-size 131072` → `--ctx-size 16384` in `llamaCmdRx580` (ai.nix): KV
   drops from ~9.6 GiB to ~1.2 GB, fits in VRAM, **zero GTT reads → decode
   becomes GPU-bound and independent of the weak PCIe link**. Recallium never
   exceeds ~2K tokens, so 16K is ample. Expected decode gain (to be A/B'd).
4. Retire the ollama-bridge (Nix change) once nothing else needs `:11434`, and
   update `docs/recallium.md` / `AGENTS.md` (they still describe the old
   bridge → r9700 architecture).

## 9. Caveats & gotchas

- **Standalone llama-server on the RX580 decodes at ~0.7 tok/s** (unexplained
  process-environment artifact: same binary/model/GPU at 32 tok/s through the
  llama-swap router). **Always benchmark through the production router**, not
  standalone servers.
- New GGUFs require a llama-swap restart (static model list).
- The rx580 router is `--models-max 1` (4 GB hard cap) — one resident model;
  other small-model users evict it (it reloads in ~5 s).
- `-fa off` is impossible with q8 KV ("quantized V cache requires flash_attn").
- Test artifacts left behind: Recallium project `rx580-test` (id 131), memories
  1091–1095; `/tmp/rx580-*.sh` scripts, `/tmp/recallium_*` prompt files.
- Revert path: repoint provider account 3's `base_url` back, or set config
  1004 active + restore its failover row, then restart the container.

## 10. Bottom line

The RX580 earns its place as the system's small-model / offload GPU. It runs
Recallium end-to-end at 10–14 s per memory while **freeing ~30 GB on the
R9700** for the coding model and SDXL — the actual purpose of the offload. Its
limits are hard (4 GB, PCIe x2) but understood: use ≤4B models, keep the KV
small enough to live in VRAM, and don't expect it to be a primary inference
GPU. Treat it as a dedicated coprocessor for high-latency-tolerant, small-model
background work.
