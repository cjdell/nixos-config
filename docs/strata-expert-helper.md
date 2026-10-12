# A second GPU as a Strata "expert helper" on zen3-nixos

**Date:** 2026-10-10 · **Status:** investigation / options analysis (no config changes made)
**Applies to:** `zen3-nixos` — Strata (`hosts/zen3-nixos/ai/strata*.nix`), Qwen3.8-Flash-Next
on the R9700 (gfx1201, HIP), KVM/5950X, B550 AORUS ELITE V2.
**Related:** `docs/strata.md`, `docs/strata-degeneration.md`, `docs/strata-hang.md`,
`docs/rx580-usefulness.md`, `docs/multi-gpu-inference.md`.

---

## TL;DR

- **What it is.** Strata can put an adaptive *expert cache* on one or more secondary GPUs
  (`--expert-cache-device1..3`), so those cards hold routed experts in VRAM, compute their
  rows, and return a reduced partial sum to the primary. It is **decode-only** work — the
  helper never runs prefill — and it does **not** touch the context window or KV cache.
- **The measured prize** (upstream issue #1184, RX 6800 + RX 6600, HIP): **+10 % / +15 % /
  +18 % decode** for 3400 / 3600 / 3800 helper slots on a PCIe 4.0 x8 link. Context and
  prefill unchanged.
- **On this box that prize is gated by three walls**, in order:
  1. **Backend/vendor** — one engine binary is one backend. Mixed AMD+NVIDIA is
     *not supported* upstream (AMD_HIP.md). A HIP primary + CUDA helper needs a private,
     unpublished cross-vendor patch.
  2. **ROCm arch coverage** — the candidate card's `gfx` arch must be in the runtime
     *and* the engine build. Verified below for nixpkgs ROCm 7.2.3.
  3. **PCIe** — the *only free slot on this board trains at Gen1 x2 = 0.5 GB/s*, ~26×
     slower than the reference measurement. **This is the wall most likely to sink it.**
- **Recommendation:** the RX 580 that is already installed **cannot** be used (gfx803,
  wave64, no ROCm). The RX 5600 6 GB is the only cleanly-supported candidate (no Strata
  patch), but its expected gain on this board's second slot is **unclear-to-negative**.
  **Do not plan on a helper until the PCIe link of the second slot is measured** — and it
  can only be improved by freeing M.2B, which is a separate decision.

---

## 1. What an "expert helper" is

Origin: upstream issue #879 ("All-logits-NaN degeneration …"), where a commenter (MKheru)
described running an R9700 alongside an NVIDIA RTX 3050 used as an expert helper through a
local patch. Strata's documented version of the same idea is `docs/SECOND_GPU.md`:

- CUDA0 (here: the R9700) keeps the dense layers, KV/state, MTP and its own expert cache.
- Up to three secondary caches fill `--expert-cache-device1/2/3` in order. Each expert has
  one owner: primary, one helper, or the CPU pool.
- The helper computes its rows while the CPU pool works; results return through private
  pinned host buffers. **Each layer waits for all participating helpers.**
- `--remote-expert-opt` optimises this path (the helper reduces its outputs to one weighted
  partial sum per token before returning). It is off by default and must be added.

Key properties for planning:

| property | value |
| --- | --- |
| Work offloaded | decode expert rows only (prefill stays on the primary) |
| KV / context | **not touched** — KV stays on the primary |
| Context cost | none (helper VRAM is for experts, not KV) |
| Transport | pinned host staging over PCIe/USB4, **no P2P required** |
| Failure mode | the primary *waits* for helpers each layer, so helper-link latency is on the critical path |

## 2. Hardware in play on zen3-nixos

| | R9700 | free slot (2nd) | RX 580 (installed) |
| --- | --- | --- | --- |
| Arch | gfx1201 (RDNA4) | — | gfx803 (Polaris) |
| VRAM | 32 GB | — | 4 GB |
| Link (live `lspci`) | **PCIe 4.0 x16 = 32 GB/s** | **Gen1 x2 = 0.5 GB/s** | Gen1 x2 = 0.5 GB/s |
| BDF | `09:00.0` | bridge `03:00.0` | `04:00.0` |

Board is a **Gigabyte B550 AORUS ELITE V2** (PCIe 3.0 chipset), CPU a 5950X, 93 GiB RAM.
The second slot's x2/Gen1 link and its lane-sharing with M.2B (Crucial P3 at `05:00.0`) are
already documented in `docs/rx580-usefulness.md` §6 — that doc also established that
**swapping cards is not an option** (the R9700 would drop onto the x2 link).

Live engine state (see `hosts/zen3-nixos/ai/strata.nix`):

- Model: Qwen3.8-Flash-Next, currently `config.ai.strataModel = "ud-iq4-xs"`.
- Expert cache (primary, R9700): **24.87 GiB** →
  - UD-IQ4_XS: **10,679 slots**, 2.385 MiB/slot, 90–93 % hit, 48–57 tok/s.
  - IQ3_S: **13,104 slots**, 1.943 MiB/slot, 92–97 % hit, 62–68 tok/s.
- KV: `--kv int8 --kv-resident 32768`, 13.7 KB/token, `--max-context 262144`,
  quant-independent. Engine build: `-DCMAKE_HIP_ARCHITECTURES=gfx1201`
  (`hosts/zen3-nixos/ai/strata-package.nix:130`).

## 3. Wall 1 — backend / vendor

One engine binary = one backend. Upstream statements:

- `docs/AMD_HIP.md`: "Other AMD architectures and **mixed AMD/NVIDIA execution in one run
  are not supported**."
- `docs/MULTI_GPU.md`: unsupported combinations include "Intel GPUs, and a **mix of NVIDIA
  and AMD cards**".

Consequences:

- **AMD primary + AMD helper** → supported (HIP helper caches, issue #1184). No Strata
  source change if the helper's arch is in the build's list.
- **AMD primary + NVIDIA helper** → needs a **private cross-vendor patch** (MKheru changed
  `remote_experts.cpp`, `remote_expert_opt.cu`, `generate.cpp`; the helper is a separately
  built CUDA library `dlopen`ed from the HIP engine). It was never published, and it would
  have to be rebased through every Strata bump.

## 4. Wall 2 — ROCm / arch coverage

The engine build must name the helper's arch (`-DCMAKE_HIP_ARCHITECTURES="gfx1201;<arch>"`)
and the nixpkgs ROCm 7.2.3 stack must carry that arch. **Measured on this box:**

| nixpkgs 7.2.3 component | gfx1010 (RX 5600) | gfx1201 (R9700) | gfx803 (RX 580) |
| --- | --- | --- | --- |
| `rocmPackages.clr` `gpuTargets` | ✅ | ✅ | ❌ |
| `rocmPackages.rocblas` (Tensile libs) | ✅ 56 libs | ✅ 56 libs | ❌ |
| `rocmPackages.hipblas` | ✅ (wraps rocBLAS) | ✅ | ❌ |
| `rocmPackages.hipblaslt` | ❌ | ✅ | ❌ |

- **gfx1010 (RX 5600): viable.** Strata added RDNA1 to its arch gate in **PR #996**
  (`gfx1010`, `gfx1011`; *"No source changes are needed"*), so the change is the one-line
  arch list plus the helper flags. The engine also requires **wave32**, which gfx1010 has.
  Caveats from #996: hipBLASLt refuses all prefill GEMMs on gfx1010 (no tuning table —
  irrelevant to a decode-only helper), and RDNA1 has no hardware `dp4a`/WMMA, so its
  expert-row compute is slower (the portable path was fine and slightly faster than the
  SDWA one: 162.7/24.3 vs 158.3/24.0 tok/s as a primary).
- **gfx803 (RX 580): not viable.** ROCm dropped Polaris after ROCm 4.0; AMD_HIP's backend
  requires wave32 while gfx803 is wave64 (the only wave64 path is a separate gfx906
  build); and gfx803 lacks the packed-byte kernels. Community gfx803 ROCm images
  (e.g. `ROCm-For-RX580`, ROCm 6.1.2) do not help, because they cannot drive gfx1201 and a
  helper must live in the **same process** as the primary.

## 5. Wall 3 — PCIe (the decisive one on this board)

The reference measurement (#1184) ran the helper at **PCIe 4.0 x8 (~13 GB/s)**. This board's
one free slot is **Gen1 x2 (0.5 GB/s)**.

One-direction bandwidth:

| link | bandwidth | vs #1184 helper |
| --- | --- | --- |
| **Gen1 x2 (this slot, measured)** | **0.5 GB/s** | **~26× slower** |
| Gen3 x2 (best case if the 5600 trains better) | ~1.97 GB/s | ~6.6× slower |
| PCIe 4.0 x8 (reference) | ~13 GB/s (meas) / 15.75 (theor.) | 1× |
| R9700's link | PCIe 4.0 x16 ≈ 31.5 GB/s | 63× faster than the slot |

Costs at 0.5 GB/s:

- **Startup cache fill** of ~4.5 GiB: ~**9.2 s** (vs ~0.35 s at 13 GB/s; ~2.3 s at Gen3 x2).
- **Steady-state decode:** helper transport is *synchronous per layer*. #1184 measured
  ~0.3–0.6 ms/layer at 13 GB/s. Scale ~26× and a ~1–3 MB/token helper round-trip becomes
  **~2–6 ms/token** against a ~19 ms decode step (52 tok/s) — 10–30 %, on the critical path.
- **Adaptive swaps** (~2.4 MB/expert moved cold→hot): ~4.8 ms each, and they batch.
- **The irony:** the helper is meant to be cheaper than the CPU pool. The primary reaches
  host RAM at ~32 GB/s, but the helper's VRAM only at 0.5 GB/s — so on this slot the CPU
  pool may genuinely be the faster path for the same expert.

**A Gen1 x2 link is very likely a dealbreaker; Gen3 x2 is marginal at best.** The x2 width
is shared with M.2B; freeing M.2B *might* raise it (spec: PCIe 3.0 x4 ≈ 3.9 GB/s), which
would be workable.

## 6. Candidate cards

| card | arch | patch? | ROCm 7.2.3? | helper slots (~) | est. decode gain | notes |
| --- | --- | --- | --- | --- | --- | --- |
| RX 580 (installed) | gfx803 | — | ❌ | — | — | wave64, pre-ROCm-4.0; unusable |
| RTX 2060 6 GB | sm_75 | ✅ cross-vendor patch | ✅ CUDA | ~1,700–2,100 | ~+10 % (if link allowed) | patch unpublished; rebase burden |
| **RX 5600 6 GB** | gfx1010 | ❌ none | ✅×3 (no hipBLASLt) | ~1,700–2,200 | ~+8 % nominal | RDNA1, unvalidated; slow per-row |
| cheap 8 GB RDNA2 (RX 6600/6700) | gfx1030/31/32 | ❌ none | ✅ | ~2,600–3,400 | ~+10–18 % | measured reference class |

Helper slot count = `usable_VRAM / bytes_per_slot`; for a 6 GB card ≈ 4–5 GiB usable.

## 7. What it would take (concretely)

For the RX 5600 6 GB, same-vendor path:

1. `hosts/zen3-nixos/ai/strata-package.nix:130`: `"-DCMAKE_HIP_ARCHITECTURES=gfx1201"`
   → `"gfx1201;gfx1010"`.
2. `hosts/zen3-nixos/ai/strata.nix`: add `--expert-cache-device1 <MiB> --remote-expert-opt`
   to `engineArgs`; set `STRATA_PRIMARY_DEVICE` if HIP enumerates the 5600 first (the R9700
   must be primary).
3. Keep `--kv`/context flags as-is — the helper does not affect KV or context.
4. Watch the `#854` PCIe-share pitfall: the primary can re-fetch experts the helper already
   holds, which *slowed* 2×RX 6900 XT from 66 to 40 tok/s before the fix. `--remote-expert-opt`
   helps; `--pcie-frac 0` is the fallback.

## 8. Recommendation & open questions

- **Do not deploy a helper yet.** The blocker is the slot's **Gen1 x2 (0.5 GB/s)** link, not
  the software.
- **First step is a measurement, not a purchase:** confirm the RX 580's slot really is the
  only candidate and re-read its `LnkCap`/`LnkSta`; if a card can ever train at ≥ Gen3 x2,
  the calculus changes. Consider whether freeing M.2B (Crucial P3) raises the slot width.
- If a card is tried, **benchmark before/after** with `--remote-expert-opt`, watching
  decode tok/s and the engine's per-request helper transfer numbers, and be ready to revert.
- **Better uses of a spare card** (no Strata involvement): a separate small model via Vulkan
  (llama.cpp) on the secondary GPU, or moving `sd-gate`/Recallium work off the R9700.
- Open questions:
  1. Would a Navi 10 card train better than the RX 580's Gen1 x2 in that slot?
  2. Does freeing M.2B restore x4? (Board diagrams vs reality.)
  3. Is the helper's per-token transfer small enough to hide behind compute at 0.5 GB/s?
     (Only a benchmark answers this.)

---

## References

- Strata issue #879 — expert helper origin (MKheru, R9700 + RTX 3050):
  <https://github.com/Niko1221/Strata/issues/879>
- Strata issue #1184 — HIP primary ordinal + helper caches; measured RX 6800 + RX 6600:
  <https://github.com/Niko1221/Strata/issues/1184>
- Strata PR #996 — accept gfx1010/gfx1011 (RDNA1); merged, no source change:
  <https://github.com/Niko1221/Strata/pull/996>
- Strata `docs/SECOND_GPU.md` (CUDA1–3 expert caches, `--remote-expert-opt`, `--peer-device`),
  `docs/AMD_HIP.md` (wave32, mixed-vendor unsupported), `docs/OLDER_GPUS.md` (per-card notes).
- Strata issue #854 (PCIe-share regression), issue #1857 (0.1.41 multi-GPU slowdown).
- `docs/rx580-usefulness.md` §6 — this board's x2/Gen1 second slot and lane sharing.
- `docs/multi-gpu-inference.md` — earlier (llama.cpp) multi-GPU options, superseded context.
