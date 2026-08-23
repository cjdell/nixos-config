# GTT by default, VRAM as cache?

Research notes on whether llama.cpp / stable-diffusion.cpp on zen3-nixos can
run with model weights in GTT (system RAM, "cheap") and VRAM used as a cache,
instead of the current unload/reload "swap dance" between models — and between
the LLM and SD.

Verified 2026-08-18 against source at:

- llama.cpp pinned rev `8b86400975fbbe29fca7f196ee208ab246a7c29f`
  (flake input `llama-cpp`; this is upstream master-era, v0.1.2)
- sd.cpp `master-625-f683c88` (pinned by nixpkgs_2 `0dd31db7…`, nixos-26.05)
- Files: `ggml/src/ggml-vulkan/ggml-vulkan.cpp`, `src/llama-model.cpp`,
  `common/arg.cpp`, `tools/server/README.md` at the llama.cpp rev;
  `examples/common/common.{hpp,cpp}` at the sd.cpp rev.

## TL;DR

- The "weights in RAM, VRAM as an LRU cache" mode **does not exist** in
  llama.cpp at any rev — no `--vram-cache` flag, no eviction code. It was
  never shipped upstream.
- llama.cpp *does* support a **GTT fallback** for weight buffers, but only via
  the env var `GGML_VK_ALLOW_SYSMEM_FALLBACK=1`, and it is **static**: once a
  buffer is placed in GTT it stays there until the model is unloaded. There is
  **no automatic "unspill"** back into VRAM when VRAM later frees up.
- Default (without the env var) on VRAM exhaustion: the model **fails to
  load** with `unable to allocate Vulkan0 buffer`. No CPU re-balance, no GTT.
- sd.cpp's `--offload-to-cpu` sounds like what we want but isn't: it streams
  *all* weights RAM→VRAM on **every graph execution** (2×/step + CLIP + VAE
  tiles) and does **not** reduce peak VRAM. RADV's driver-level GTT spill
  already gives the "GTT default" behavior for SD.
- What IS achievable: `GGML_VK_ALLOW_SYSMEM_FALLBACK=1` + `--models-max N` on
  the r9700 router (multi-resident, no swapping; overflow models run at PCIe
  speed), and a relaxed `--min-vram-gib` in sd-gate (SD runs at GTT-spill
  speed with the LLM resident instead of unloading it). See the proposal at
  the bottom.

## llama.cpp at the pinned rev

### The allocation ladder (`ggml-vulkan.cpp`)

`ggml_vk_create_buffer_device()` (L3573) picks the memory type for a weight
sub-buffer. For a discrete GPU with defaults, the alternatives are
device-local only; **if VRAM is exhausted the load fails**. Env vars (all
read at device init, L6168–6184; all default off):

| env var | effect |
| --- | --- |
| `GGML_VK_ALLOW_SYSMEM_FALLBACK=1` | appends `{eHostVisible\|eHostCoherent}` (the GTT heap) as the last resort for device buffers → weights land in GTT instead of failing |
| `GGML_VK_PREFER_HOST_MEMORY` | prefer host-visible memory (not used here) |
| `GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM` | force device-local only |

With the fallback env var set, the discrete-GPU ladder becomes:
rebar (device-local + host-visible + coherent, if the card exposes such a
memory type) → device-local → GTT. The Vega 8 iGPU (UMA) branch is
unaffected — it already prefers host-visible memory.

Weight buffers are sub-allocated into ≤ 1 GiB chunks
(`suballocation_block_size`), so each Vulkan allocation is small and the RADV
`maxMemoryAllocationSize` ~4 GiB cap is not hit by llama.cpp (unlike the
SDXL VAE graph, which is why `--vae-tiling` is required there).

### No cache, no eviction, no promotion

- `evict` / `LRU` → 0 matches in `ggml-vulkan.cpp`. Nothing evicts weight
  tensors, and nothing *promotes* GTT-resident buffers back into VRAM.
- A buffer is bound once (`bindBufferMemory`) at allocation and lives until
  the model instance exits.
- `-cram N` is the KV-cache-in-RAM budget (idle slots), unrelated to weights.
- `-ngl auto` == `-ngl all` at this rev (`n_gpu_layers()`); `--fit` adjusts
  *unset* args before load — it does not rescue a failed weight allocation.
- `-ot/--override-tensor` accepts only device-default buft names; on this box
  that is `CPU`, `Vulkan0`, `Vulkan1`. (`host` is **not** valid, even though
  the `--no-host` flag exists.)

### Router mode

- Each model = its own llama-server instance process; `--models-max N`
  (default 4, 0 = unlimited) caps simultaneous instances. LRU eviction beyond
  N kills the oldest instance, freeing its VRAM **and** GTT/RAM.
- Instances inherit the router's env, so `GGML_VK_ALLOW_SYSMEM_FALLBACK=1`
  set in the systemd unit reaches every model.

## Why GTT is slow (bandwidth math)

Generation is bandwidth-bound: every token reads (nearly) all active weights.

- PCIe 4.0 x16 ≈ 32 GB/s (5.0 ≈ 63 GB/s) vs ~1 TB/s VRAM.
- A ~16 GB Q4 model in GTT ⇒ ~16 GB read per token ⇒ ~0.5 s/token ≈ 2 t/s.
- MoE (A3B) models read only the dense layers + active experts per token, so
  the GTT cost per token is smaller (~4–6 GB) ⇒ maybe ~5–8 t/s. Usable for
  background agents, poor for interactive coding.
- This bandwidth reality is presumably why upstream never shipped a
  "VRAM cache" for weights: for generation the *whole* active working set is
  hot on every token, so an LRU cache would mostly miss anyway.

## sd.cpp at the pinned rev (`master-625-f683c88`)

- `--backend diffusion=vulkan0,clip=vulkan0,vae=vulkan0` — per-module device
  assignment.
- `--max-vram` — float; `-1` = auto-detect free VRAM as the graph-cut budget,
  sparing 1 GiB.
- `--vae-tiling` — required (RADV 4 GiB single-allocation cap vs the ~8.5 GB
  SDXL VAE decode graph).
- `--offload-to-cpu` — help says "place the weights in RAM to save VRAM, and
  automatically load them into VRAM when needed", but it is **per-graph
  streaming**: every `compute()` allocates a fresh full-size VRAM params
  buffer, copies ALL weights RAM→VRAM, computes, then frees it. That happens
  2× per denoise step (cond + uncond) plus CLIP and per VAE tile. It does
  **not** shrink peak VRAM (the weights are in VRAM during every compute
  anyway) and adds ~0.3–0.5 s/step of PCIe copies at 1024×1024. **Not a fix
  for coexistence — do not enable.**
- The gate already relies on RADV's driver-level GTT spill: with the LLM
  resident, SD runs at GTT-spill speed (measured ~36 s / 8 steps @ 512×512 vs
  ~25 s / 30 steps @ 1024×1024 with VRAM free). GTT spill for SD is the
  status quo; the `--min-vram-gib 10` LLM unload was added purely to make SD
  fast again.

## The GTT unspill question

> If a model spilled to GTT and the previous process then frees VRAM, does it
> automatically move back into VRAM?

**No.** Verified in source:

1. The GTT placement decision is made once, at buffer allocation
   (`ggml_vk_create_buffer` → `allocateMemory` + `bindBufferMemory`).
2. There is no migration/promotion code: ggml-vulkan has no mechanism that
   re-allocates or copies GTT-resident buffers into VRAM when VRAM frees up,
   and no driver-event hook that could trigger it.
3. The kernel driver (RADV / amdgpu TTM) does not proactively migrate
   GTT-spilled allocations back either — buffers stay where they were
   allocated until destroyed.

The only ways a spilled model gets back into VRAM:

- **Unload + reload** — llama-swap's LRU eviction (models beyond
  `--models-max`) or `POST /api/models/unload` kills the instance; the next
  request spawns a fresh one, which re-attempts device-local allocation and
  succeeds if VRAM is free by then. This is exactly the "swap" the
  multi-resident design tries to avoid, so it is a per-model, manual decision.
- **Kill and respawn the process** — sd-gate does this for SD after 120 s
  idle, which is why SD "unspills" naturally: every spawn re-allocates with
  whatever VRAM is free at that moment.

Practical consequence: with `--models-max N` + the fallback env var, the
model loaded **first** (when VRAM is free) keeps VRAM; later models stay in
GTT for as long as they remain resident — even after VRAM frees up. If you
observe "it doesn't appear to unspill", that is exactly the expected
behavior.

## Proposed config (NOT yet applied — pending decision)

If we want "GTT by default, VRAM held by the hot model, no swapping":

1. `hosts/zen3-nixos/ai/llama-swap.nix`, llama-swap `environment`:
   ```nix
   GGML_VK_ALLOW_SYSMEM_FALLBACK = "1";
   ```
2. r9700 router: `--models-max 1` → `--models-max 3` (tune by RAM: each
   resident model also holds up to `-cram` of idle KV in RAM).
3. sd-gate: `--min-vram-gib 10` → `--min-vram-gib 4` — with the coding model
   resident (~26 GB, ~6 GiB free) the gate check passes, so SD runs at
   GTT-spill speed **without unloading the LLM**; the unload stays only as a
   safety valve when VRAM is genuinely tight.

Expected outcome: no unload/reload for model switches or SD use. Costs:
GTT-resident models generate at PCIe speed (see bandwidth math) and stay in
GTT until manually reloaded; VRAM is never "reclaimed" from a resident model.

## Open items / how to verify on the host

- Check actual system RAM: `free -h` (expect ≥ 128 GiB given
  `amdgpu.gttsize=90112`). Budget RAM = Σ(weights of resident models) +
  N × `-cram`.
- Confirm the deployed sd-server version: `sd-server --version` and
  `journalctl -u sd-gate` (it must parse `--backend`/`--max-vram`; the pinned
  nixpkgs_2 `0dd31db7…` provides master-625-f683c88, which does).
- Watch where weights land: llama-server logs (`ggml_vulkan: Device memory
  allocation of size ... failed` lines mean the fallback fired) and
  `/sd-status/status` for the SD side.
- Whether RADV's driver-level GTT spill or the llama.cpp env-var fallback
  fires first for sd-server is driver-dependent; both end at GTT speed.
