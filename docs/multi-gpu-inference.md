# Using the RTX 2060 together with the Vega iGPU for llama.cpp

**Date:** 2026-08-14 · **Status:** research report (no config changes made)
**Applies to:** `zen3-nixos`, llama-swap → llama-server (Vulkan backend), local fork
`/home/cjdell/Projects/llama.cpp` (HEAD `a8c202312`, upstream base `b10297`).

---

## TL;DR

- **"KV on the RTX, experts on the Vega" is not something llama.cpp can do.** There is no
  mechanism to place attention+KV on one GPU and an MoE layer's experts on another, inside
  one layer. KV placement is always tied to weight placement.
- What *does* work today, in order of expected payoff for your setup:

  1. **Speculative decoding — small draft model on the RTX, big MoE on the Vega.**
     This is the true "divide the workload" option and it's stable. Expect roughly
     **1.5–2.5× decode speedup**, no model quality change, nothing experimental.
  2. **`--split-mode layer` with `--tensor-split`** — move ~⅓ of the layers (weights *and*
     their KV, they travel together) onto the RTX. Expect a **modest +30–50 % decode** win
     and a bigger prefill win. Works today on the Vulkan backend.
  3. **Two independent models at once** (big MoE on the Vega, small/fast model on the RTX)
     via llama-swap model entries — each GPU fully busy with different workloads.
- **`--split-mode tensor` is not usable for you yet:** on Vulkan it crashes/slow (the fix,
  PR #25051, is an unmerged draft), and with a 6 GB vs 88 GB memory imbalance every layer
  would be gated by the Vega anyway.

---

## Your hardware (measured)

| | Vega 8 iGPU (5700G) | RTX 2060 |
|---|---|---|
| Memory | 512 MB dedicated + **88 GB GTT** (system RAM, unified) | **6 GB GDDR6** |
| Bandwidth | ~50 GB/s (DDR4-3200 dual channel, shared) | **~336 GB/s** (~6.7×) |
| FP32 compute | ~1.8 TFLOPS | ~6.5 TFLOPS (~3.6×) |
| Vulkan driver | Mesa RADV ("AMD Radeon Graphics (RADV RENOIR)") | NVIDIA proprietary Vulkan |
| Today's device list | `vulkaninfo`: device 0 | not installed yet |

The "88 GB VRAM" is **GTT** (Graphics Translation Table over system RAM), confirmed by
your own `vulkan-crash.md` note (512 MB real VRAM + 88 GB GTT). It's not slow "VRAM" —
it's *faster than plain CPU* but far below any dGPU's memory bandwidth.

Your main model, `Qwen3-Coder-REAP-25B-A3B-Rust-Q4_K_M.gguf`, is **15.1 GB**. It cannot
fit in the RTX's 6 GB at all; the RTX can at most host ~⅓ of it (≈5.5 GB).

Decode math for that model (Q4_K_M ≈ 4.85 bpw, 3 B active params per token, bandwidth-bound):

- **Vega only (today):** ~1.8 GB read/token ÷ 50 GB/s ≈ 36 ms → **~25 tok/s ceiling**, so
  your real-world ~15–20 tok/s makes sense.
- **⅓ of layers on RTX:** RTX share ≈ 0.6 GB ÷ 336 GB/s ≈ 2 ms; Vega share ≈ 1.2 GB ÷
  50 GB/s ≈ 24 ms; total ≈ 26 ms → **~38 tok/s ceiling (+~40 %)**.

Real gains depend on the model split balance, so measure (plan at the bottom).

---

## How llama.cpp multi-GPU actually works

From the upstream docs (`docs/multi-gpu.md`, current master = your fork's base) and the
llama-server help:

| `--split-mode` | What it does | KV cache placement |
|---|---|---|
| `none` | One GPU only (`--main-gpu` picks it) | on that GPU |
| `layer` (**default**) | Pipeline parallelism: each GPU owns a contiguous slice of **whole layers** (attention *and* that layer's experts). | **KV for layer *l* lives on the GPU that owns layer *l*** |
| `row` | **Deprecated.** Old row-split path, "comparatively poor performance", **splits only dense weights** — experts are *not* distributed. | on `--main-gpu` |
| `tensor` | **EXPERIMENTAL.** True tensor parallelism via a "meta device"; every layer is split across all GPUs with an all-reduce per layer. | **split across GPUs** along with attention heads |

Other relevant knobs:

- `--tensor-split N0,N1,...` (`-ts`): fraction of the model per GPU. **The order follows the
  `--device` list order.** In `layer` mode, omitted = automatic split proportional to each
  GPU's memory.
- `--device` (`-dev`): restrict which devices are used, by name from `--list-devices`
  (e.g. `Vulkan0,Vulkan1`). Always pass this once the 2060 is installed — `vulkaninfo`
  currently also lists a software **llvmpipe** device that you never want picked.
- `--fit`: auto-fits unset args to device memory (default on). **Not supported with
  `tensor`**, and *not* reliable for an explicit dGPU+iGPU mix (see gotchas).
- `--no-kv-offload`: keeps the whole KV cache in system RAM instead. The only "KV goes
  elsewhere" control that exists.

### What this means for "KV on RTX, experts on Vega"

There is no per-component device assignment in llama.cpp (nor in Ollama, KoboldCPP,
exllamav2 — no local engine offers it). The mapping you described — fast dGPU doing
attention/KV while the big-memory iGPU holds all the expert weights — is an
expert-parallel scheme that only datacenter stacks (DeepSpeed-style tensor+expert
parallelism) implement. In llama.cpp you get these approximations instead:

- **Layer mode:** the RTX holds *whole* layers: their attention weights, their KV cache,
  and their experts. "Some KV on the RTX" is exactly "some layers on the RTX".
- **Tensor mode:** each layer is split across both GPUs, KV split by heads — but every
  layer waits for the *slowest* GPU, and with 6 GB vs 88 GB the RTX would hold only a
  small row-fraction of each tensor. Bad fit even once it stops crashing.
- **Row mode:** deprecated, and it does *not* distribute MoE experts (dense weights only)
  — so it can't give you "experts on Vega" either.

---

## Backend reality check: why it has to be Vulkan

To use both GPUs in **one** llama-server process, both must be reachable through the same
backend:

| Backend | Vega iGPU | RTX 2060 |
|---|---|---|
| **Vulkan** (your `llama-cpp-uma` vulkan build) | ✅ | ✅ (NVIDIA Vulkan driver) |
| ROCm (`llama-cpp-uma` rocm build) | ✅ | ❌ |
| CUDA | ❌ | ✅ |

So **the Vulkan build is the only one that can ever see both GPUs.** Good news: Vulkan
multi-GPU *does* work for layer mode — e.g. dual Intel Arc B70 on `-sm layer` runs fine
(issue #25286: "The Vulkan backend handles multi-GPU splitting correctly"). llama.cpp
technically registers devices from every compiled backend (a DGX Spark owner found their
model "split between CUDA and Vulkan" — #23897), but mixed-backend use is an untested
side effect, not a feature. Don't build a CUDA+Vulkan franken-binary for this.

### Why `--split-mode tensor` is a no-go for now

1. The Vulkan path for tensor mode is broken/slow on master: PR #19378 (merged Apr 2026,
   which added `tensor`) says *"Vulkan technically works at short contexts but the
   performance is bad, at long contexts there are also stability issues."*
2. The fix — PR #25051 "vulkan: add allreduce function with cross-device CPU proxy and fix
   Tensor Parallel crash" — is **still a draft (open, unmerged)**. Even in its best case
   on two *fast* NVIDIA Vulkan GPUs, Qwen3.5-35B-A3B decode went **82 → 68 tok/s** vs layer
   mode (prefill improved 1916 → 2290). Your iGPU→PCIe→dGPU all-reduce would be slower still.
3. Tensor mode **forbids quantized KV** (f16/bf16/f32 only) and requires flash-attn on.
4. Tensor mode breaks the server prompt cache (`prompt_save` aborts the process — #26128,
   also reported under `--split-mode tensor` in #21765/#21876). That alone kills it for
   your llama-swap/Recallium workflow.

Revisit it after #25051 lands and the meta-buffer prompt-save bug is fixed — but expect it
to still lose to layer mode given the 6 GB/88 GB asymmetry.

---

## Plan 1 — Speculative decoding: draft model on the RTX (recommended first)

llama-server can run a **separate small draft model on a different GPU than the target**
(`--spec-draft-device` / `-devd`). The big MoE stays entirely on the Vega (unchanged
behavior, full 88 GB/262 K context), while the RTX runs a ~0.6–1.7 B draft that proposes
tokens the big model then verifies in one pass. Accepted tokens are typically 60–80 %,
so you get close to (1 + accept rate × draft length) × speed. For your ~20 tok/s Vega
decode, this is the biggest single win available.

Requirements:

- The draft model must share the target's tokenizer/vocab. Qwen3-family drafts (e.g.
  `Qwen3-Coder-1.5B` for the REAP/`Qwen3-Coder` targets; `Qwen3.5-0.8B` for the Qwen3.6
  targets) work. You don't currently have a small draft GGUF in `/home/cjdell/Models` —
  one ~1–2 GB download is needed.
- The RTX's 6 GB holds the draft with room to spare.

Sketch (Vulkan device names to be confirmed with `--list-devices` after installation):

```sh
llama-server -m /home/cjdell/Models/Qwen3-Coder-REAP-25B-A3B-Rust-Q4_K_M.gguf \
  -dev Vulkan0 \
  -devd Vulkan1 \
  -md /home/cjdell/Models/Qwen3-Coder-1.5B-Q8_0.gguf \
  --spec-draft-n-max 16 --spec-draft-p-min 0.6 \
  -c 262144 --metrics --reasoning-preserve
```

Tuning: `--spec-draft-n-max` 8–32 (higher = more drafts per verify), and watch the
`/metrics` counters `spec_decode_num_accepted_tokens_per_pos` / `..._total` for the real
acceptance rate. Note your fork's MTP GGUFs (`*-MTP-Q4_K_M.gguf`) are a related but
different trick — MTP heads live inside the *target* model, so they don't use the RTX.

### Plan 1b — MTP (built-in speculative decoding, Vega-only)

MTP = a draft head embedded in the same GGUF; you opt in with two flags
(`--spec-type draft-mtp --spec-draft-n-max N`). Merged into llama.cpp May 2026
(PR #22673, builds 9200+); your fork is b10297-based and **supports it** — verified
`draft-mtp` in `common/speculative.cpp`. Useful write-up:
<https://mer.vin/2026/05/run-qwen-3-6-mtp-in-llama-cpp-faster-local-inference-with-built-in-speculative-decoding/>

Verified on this machine (2026-08-14, binary grep of the GGUFs):

- `Qwen3.6-27B-Fable-Fus-711-UnHeretic-NM-DAU-NEO-MAX-NEO-MTP-Q4_K_M.gguf` **does
  contain a real MTP head** — metadata key `qwen35.nextn_predict_layers` + tensors
  `blk.64.nextn.*` (the non-MTP twin has none).
- But it is a **dense** 27B (no `expert_count` keys) on the `qwen35` arch. Dense 27B
  reads ~all 16.5 GB of weights per token: at the Vega's ~50 GB/s that's ~3 tok/s, and
  MTP's ~2× lands at ~5–6 tok/s. It's commented out in `ai.nix` for a reason — the
  Vega only shines on A3B-class MoE.
- To actually benefit on the Vega you'd want an **A3B-MoE MTP GGUF** (e.g.
  `ggml-org/Qwen3.6-35B-A3B-MTP-GGUF` or an Unsloth MTP pack, ~21 GB). Realistic gain
  is the PR-thread community bench, not the article headline: 35B-A3B on 6 GB VRAM +
  64 GB RAM went **22.9 → 29.4 tok/s (+28 %)** at `--spec-draft-n-max 2`. The
  article's "~100 tok/s" is Strix-Halo-class hardware (256 GB/s+), not this box.

```sh
llama-server -m /home/cjdell/Models/<A3B>-MTP-Q4_K_M.gguf \
  --spec-type draft-mtp --spec-draft-n-max 2 \
  -c 262144 --metrics --reasoning-preserve
```

- MTP is a **Vega-only** speedup (the head runs on the target's GPUs) — an
  *alternative* to Plan 1's external draft, not a complement (you can't run
  `draft-mtp` + an external draft model together; ngram-* can be stacked on MTP but
  that's experimental). If the RTX is installed, Plan 1 still looks like the bigger
  win for A3B models; MTP is the free, no-download win that works today on the Vega.
- Caveats: prompt processing can get **slower** with MTP (extra embedding transfers) —
  relevant for Recallium's large system prompts. Start with n-max 2 on MoE and watch
  the acceptance counters; MTP heads on frankenmerges are unproven (acceptance rate
  will tell) — the official ggml-org MTP GGUFs are the safe reference.

**Which quant to download (2026-08-14, `unsloth/Qwen3.6-35B-A3B-MTP-GGUF`):**

| File | Size | Vega decode ceiling¹ | Notes |
|---|---|---|---|
| `UD-Q3_K_XL` | 16.0 GiB | ~33 tok/s (MTP ≈ 40+) | **Recommended for this box** — best tok/s-per-quality on the bandwidth-bound Vega; ⅓ of it fits the RTX 2060 later |
| `UD-Q4_K_XL` | 21.3 GiB | ~25 tok/s (MTP ≈ 31) | Unsloth's own reference quant for llama.cpp MTP; zero quality risk |
| `UD-Q4_K_M` | 21.1 GiB | ~25 tok/s (MTP ≈ 31) | Same quality tier as your existing 35B/REAP Q4_K_M files |
| `UD-IQ3_XXS` | 13.1 GiB | ~40 tok/s (MTP ≈ 50) | Speed pick; noticeably better than IQ2 but a step below Q3_K_XL in quality |
| `MXFP4_MOE` | 20.7 GiB | ≈ Q4 class | Native MXFP4; your Vulkan build has mxfp4 shaders (verified) — fine to use |
| `UD-IQ2_M` / `UD-IQ1_M` | 11.0 / 10.6 GiB | ~48 / ~50 tok/s | Only if raw speed trumps quality; MTP acceptance drops at this level |
| `UD-Q8_0` (Q8_K_XL) | 35.2 GiB | ~15 tok/s | Not worth it here — memory is free but the Vega is bandwidth-bound; 2× slower decode than Q4 for no practical gain |

¹ The Vega reads only the ~3 B *active* params per token; ceiling ≈ active_bytes ÷ ~50 GB/s.
Real-world is ~60–75 % of the ceiling. MTP column assumes +25–30 % (n-max 2).

Rules of thumb for this machine: memory is never the constraint (88 GB GTT),
bandwidth is — so **smaller quant = proportionally faster decode**, and the MoE's
256-expert/8-active layout tolerates Q3-class quants far better than dense models
(UD keeps sensitive tensors at higher bits). Two operational notes from Unsloth's card:
**`-np > 1` and `--mmproj` are not supported with MTP** — run `-np 1` and pass
`--no-mmproj` (the card's reference command uses `-c 8192 -fa on -np 1`; you can keep
`-c 262144`).

## Plan 2 — Layer split: ⅓ of the model on the RTX (works today)

Move ~⅓ of the layers onto the RTX. Those layers' compute (~6× bandwidth, ~3.6× FLOPs)
runs much faster, and their KV rides along on the RTX (frees GTT pressure + reduces Vega
attention work). With a 15 GB model, ~5–5.5 GB on the RTX is the safe budget.

```sh
llama-server -m /home/cjdell/Models/Qwen3-Coder-REAP-25B-A3B-Rust-Q4_K_M.gguf \
  -ngl all -sm layer -dev Vulkan0,Vulkan1 -ts 2,1 \
  -c 262144 --metrics --reasoning-preserve
```

- `-ts 2,1` = RTX gets ⅓ (~5 GB). Tune toward `-ts 1,1` (½ = 7.5 GB, too big — watch the
  `load_tensors:` log for per-device `model buffer size` lines and stay under ~5.5 GB on
  the RTX; leave room for its KV share + compute buffers).
- `-ts` order follows `-dev` order — decide which device is which after `--list-devices`.
- `--fit` can't plan an explicit dGPU+iGPU mix (PR #22922 explicitly lists it as
  unsupported) — set `-ts`, `-c`, `-ngl` explicitly and leave nothing to auto-fit.
- Expect the real gain to be smaller than the raw math above (pipeline handoff per token,
  MoE expert-group granularity when the splitter balances layers); measure before/after.

## Plan 3 — Two models, both GPUs busy (via llama-swap)

Because both GPUs are Vulkan devices in one build but llama-swap spawns *separate*
llama-server children per model, you can simply dedicate one GPU to each model entry:

- `vulkan` (current entry, Vega only): the big MoE, `-dev Vulkan0`.
- a new `rtx` entry: a small/fast or differently-tuned model with `-dev Vulkan1`.

Perfect for concurrent heterogeneous workloads (e.g. Recallium's chat on the Vega while a
quick coding model answers on the RTX). No changes to how anything behaves, just
bandwidth partitioning.

---

## Gotchas specific to this machine

1. **Vega stability at long context:** your own `vulkan-crash.md` documents `DeviceLost`
   (amdgpu ring timeout) at ~50–60 K context. The `amdgpu.lockup_timeout=10000` kernel
   param in `ai.nix` is the existing mitigation. Moving ~⅓ of the per-layer work off the
   Vega may reduce lockup pressure, but don't expect a fix.
2. **llvmpipe is enumerated.** `vulkaninfo` shows a software device (llvmpipe). After
   installing the 2060, always pass `-dev` explicitly so neither the GPU list nor auto-fit
   can pick it (the backend normally filters software devices, but don't rely on it).
3. **Device order/names change once the 2060 is installed.** Run `--list-devices` first;
   the RTX may enumerate as `Vulkan0` and the Vega as `Vulkan1`. `-ts` order must match
   your `-dev` order. Use names, not indices, in config.
4. **`--fit` doesn't understand dGPU+iGPU** (PR #22922, "Explicit dGPU + iGPU: Not
   covered… Follow-up needed"). Set everything explicitly (Plan 2 does).
5. **Tensor mode + server prompt cache = crash** (#26128 / #21765): if you ever try
   `-sm tensor`, expect `GGML_ASSERT(tensor->data != NULL)` in `prompt_save()` once more
   than one slot is used. Workaround `--cache-ram 0`, but that's a good reason to stay on
   `layer`.
6. **Headless secondary GPU VRAM eviction:** the RTX will be a secondary/headless GPU; if
   it idles long enough the driver may reclaim VRAM (there's a draft heartbeat PR #25214
   for this). Your llama workloads keep it busy, so likely a non-issue.
7. **KV sizing:** 262 K context at default f16 KV ≈ 0.5–1 GB per model — fine on either
   GPU. `-ctk q8_0 -ctv q8_0` halves it but is incompatible with future `-sm tensor`.
8. **autoRollback:** this report changes nothing; if you later edit `hosts/zen3-nixos/ai.nix`
   and rebuild, remember `sudo nixos-confirm` afterwards.

---

## Suggested experiment plan

1. Install the 2060; confirm both GPUs appear: `vulkaninfo --summary` and
   `llama-server --list-devices` (from the `llama-cpp-uma` vulkan build).
2. **Baseline:** with the current `vulkan` model entry, read tok/s from `/metrics`
   (`predicted_tokens_seconds` / `llamacpp:tokens_predicted_seconds_total`) or a
   `/v1/chat/completions` with `"timings_per_token": true`.
3. **Plan 2:** add a temporary model entry with `-sm layer -ts 2,1`, compare decode and
   prefill (long-prompt prefill gains are where layer-split shines). Tune the ratio up to
   the RTX's ~5.5 GB budget.
4. **Plan 1:** download a matching small Qwen3 draft, run with `-devd Vulkan1`, check
   `spec_decode_num_accepted_tokens_per_pos_total` in `/metrics`; tune `--spec-draft-n-max`.
5. Keep whichever wins; consider combining (draft on RTX while the Vega runs the full
   model is Plan 1 — if you also layer-split, the draft and target can share the RTX, but
   keep the target's RTX share small enough to leave draft room).

---

## References

- llama.cpp `docs/multi-gpu.md` (split modes, KV placement, tensor-mode requirements):
  https://github.com/ggml-org/llama.cpp/blob/master/docs/multi-gpu.md
- llama-server `tools/server/README.md` (`--split-mode`, `--tensor-split`, `--device`,
  `--spec-draft-*`): https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md
- PR #19378 — `--split-mode tensor` (meta backend; "Vulkan… performance is bad, at long
  contexts there are also stability issues"): https://github.com/ggml-org/llama.cpp/pull/19378
- PR #25051 (draft) — Vulkan allreduce + tensor-parallel crashfix, with RTX 3080+5060 Ti
  Vulkan layer-vs-tensor benchmarks: https://github.com/ggml-org/llama.cpp/pull/25051
- Issue #25286 — dual-GPU Vulkan `-sm layer` works (Intel Arc B70): https://github.com/ggml-org/llama.cpp/issues/25286
- PR #23897 — "llama: only use one iGPU device by default" (mixed CUDA+Vulkan split
  observed): https://github.com/ggml-org/llama.cpp/pull/23897
- PR #22922 — `--fit` host-memory accounting for iGPU; "Explicit dGPU + iGPU: Not covered":
  https://github.com/ggml-org/llama.cpp/pull/22922
- Issue #26128 — server prompt cache crashes with non-trivial backends (RPC, `-sm tensor`):
  https://github.com/ggml-org/llama.cpp/issues/26128
- Issue #25224 — MoE + small VRAM: auto-fit offloads experts to system RAM, per-token
  H2D transfers dominate generation (why the RTX should only take whole layers):
  https://github.com/ggml-org/llama.cpp/issues/25224
- PR #25214 (draft) — headless/secondary GPU VRAM eviction heartbeat: https://github.com/ggml-org/llama.cpp/pull/25214
