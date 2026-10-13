# Strata maintainer report — draft (2026-10-13)

> **Status 2026-10-13 (after this draft):** we moved the Strata **runtime** to
> **ROCm 10.0.0** and the poisoned-context fires stopped — 0 in 1911 requests,
> against 2 in 1399 on ROCm 7.2.3 over the same window, same binary and source.
> That is the A/B the "ROCm version note" below asks for, now run in production
> here. The posts below remain the report of the **7.2.3** failure; a short
> paragraph has been added to the note recording the result and the fix.

Two distinct failure classes on one box, posted separately:

- **A. Poisoned contexts / all-NaN logits** → comment on **#879**
  (`https://github.com/Niko1221/Strata/issues/879`), as a follow-up to our
  2026-10-05 comment (`cjdell`).
- **B. Hang → `SIGABRT` → GPU reset** → comment on **#1569**
  (`https://github.com/Niko1221/Strata/issues/1569`, gfx1201 + `exit code -6`),
  with a one-line cross-ref into **#1705**
  (`https://github.com/Niko1221/Strata/issues/1705`) because our result
  contradicts its fix. `#29` is **closed**, so the engine's "report it at …/issues"
  line needs a live thread.

---

## POST A — target: issue #879

**Title/lead:** 0.1.43 on a single R9700 (ROCm 7.2.3, Linux): the guard now recovers,
but it still fires ~4×/day; per-stage audit gives raw bits for *every* fire

Niko1221 — answering your three points from 2026-10-11, on 0.1.43 with no local
patch of any kind (no CUDA-helper patch, nothing beyond the two int8-KV clamps we
have carried since 0.1.41 — see note at the end):

1. **Yes, it still fires on 0.1.43 without any helper patch.** Single R9700, HIP
   only, no second GPU involved. #1892's guard recovers as designed (drops the
   caches, re-reads from token 0, retries once) and never emits `!`, but the
   poison is still produced: **4 fires on 0.1.43 between 2026-10-12 18:19 and
   2026-10-13 12:21 BST** (positions 102,465 / 145,770 / 163,011 / 131,417).
2. **Not yet run** the `STRATA_PREFILL_CPU_SHARE=0` / `--pcie-frac 0` / power-limit
   A/Bs. Our current defaults: `--pcie-frac` is **unset** (so the new measured-PCIe
   default is on), `STRATA_PREFILL_CPU_SHARE` unset, no power-limit override.
   We can run those next if you want them before anything else.
3. **`expert cache 10679 slots`** (24.08 GiB VRAM; 31.35 GiB page-locked in RAM).
   Our per-stage dump prints on **every** fire, not just the first — four fires
   below. **The bits are always `0x7fc00000`** (canonical positive quiet NaN),
   never the CUDA reporter's `0x7FFFFFFF`.

### Environment

| | |
|---|---|
| GPU | AMD Radeon AI PRO R9700 32 GB, `gfx1201`, single card, no helper GPU |
| OS / kernel | NixOS, Linux 7.2.9, in-kernel amdgpu |
| ROCm | `clr` 7.2.3, `hipblaslt` 7.2.3, `hipblas` 7.2.3, `rocm-runtime` 7.2.3, `rocm-comgr` 22.0.0-rocm |
| Engine | 0.1.43 (`7695859a`), HIP/gfx1201, `/nix/store/1s8ca3glsa0arp6hk39xnqv6sc7rkcgp-strata-0.1.43/bin/strata` |
| Model | Qwen3.8-Flash-Next UD-IQ4_XS (Unsloth), native pack |
| Cache | `10679` GPU slots, 24.08 GiB VRAM; 31.35 GiB page-locked RAM; pre-filled from the profile |
| SMU fw | 104.80.0 (`0x00685000`) |

Command:

```
bin/strata --serve --pack /home/cjdell/Strata/pack/ud-iq4-xs --native .../Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf
  --expert-profile .../expert-profile.bin --expert-cache auto --prefill auto --spec 4 --spec-min-p 0.5
  --mtp /home/cjdell/Strata/mtp/rt --max-context 262144 --kv int8 --kv-resident 32768 --resident-budget-gib 55
```

Env: `HIP_VISIBLE_DEVICES=0`, `HSA_USERPTR_FOR_PAGED_MEM=0`, `STRATA_KERNEL_AUDIT=1`.

### The four fires (0.1.43)

Every one is a **prompt read** (`before the first token`), CPU/miss path clean,
first poison in the **GPU expert-cache HIT rows of a GDN layer**, and every
non-finite value is `0x7fc00000`:

Fire 1 (`#879`, 2026-10-13 01:36 BST, position 102,465):
```
layer trace: first poisoned GPU cache-hit rows at layer 20 (GDN)   [input 21]
first non-finite HIT value: row 5 (token 0, expert slot 5), col 2048, bits 0x7fc00000
kernel-stage audit: first non-finite in gate (gu kernel) of layer 47, flat 9696, bits 0x7fc00000
planned-GPU-row audit: layer 20, row 25 (token 2, slot 5), col 352, bits 0x7fc00000, expert 5
mapped miss rows: 0 of 102400 non-finite, max|x| 0.1887
```
Fire 2 (2026-10-13 02:23, position 145,770): cache-hit rows layer 20 (input 21);
HIT row 3 (slot 3) col 768; stage gu layer 47 flat 320; planned layer 20 row 14
(token 1, slot 4) col 1120 expert 4; miss 0/102400, max|x| 0.2536.

Fire 3 (2026-10-13 02:30, position 163,011): cache-hit rows **layer 4** (input 5);
HIT row 5 (slot 5) col 1472; stage gu layer 47 flat 1056; planned layer 4 row 0
(token 0, slot 0) col 2048 expert 0; miss 0/102400, max|x| 0.3728.

Fire 4 (2026-10-13 12:21, position 131,417): cache-hit rows **layer 16** (input 17);
HIT row 3 (slot 3) col 2080; stage gu layer 47 flat 384; planned layer 16 row 4
(token 0, slot 4) col 1568 expert 4; miss 0/102400, max|x| 0.3287.

### Two things we'd like you to read off this

- **The bits are canonical qNaN `0x7fc00000`, never `0x7FFFFFFF`.** On HIP the
  first non-finite is an ordinary NaN from real arithmetic in all four fires,
  not the all-`0xFF` `INT32_MAX`-shaped write the CUDA reporter sees. Our
  `routed total (hits+misses)` probe reads `-1` (never poisoned); the CPU miss
  publish is clean every time (0 of 102,400). It is always the **GPU cache-hit
  expert row write** that first goes bad.
- **The stage audit always says "gate (gu kernel) of layer 47"** while the layer
  trace names layer 4 / 16 / 20. Layer 47 is fixed across all four fires, the
  layer trace is not. Is that what you expect (the last layer's probe runs first
  / the record is last-wins), or is it a bug in the dump ordering? If it is real,
  layer 47's `gu` output looks like a constant first-touch point.

### ROCm version note

MKheru's 2026-10-12 cross-build (0.1.43 on ROCm 10.0.0 = 0 fires; 7.2.1 libs =
fires) points squarely at the 7.2.x runtime. We are on **7.2.3** and fire the
same way, which is a third data point for "7.2.x libraries, not the compiler".

One caveat on that A/B, though: **ROCm 10.0.0 is not "two majors after 7.2" — AMD
never shipped 8 or 9.** The 7.x stable line ended at 7.2 (ours), the 7.9–7.14
tech-preview line followed, 7.14 put the whole stack on the new **TheRock** build
and release system (components moved repositories), and 7.14 then jumped straight
to 10.0 as an intentional renumber. So 7.2.x-vs-10.0.0 also swaps the build system,
which confounds "the old library misbehaves" with "the stack was rebuilt". A
**7.14** run would separate the two. We can build 7.14 and/or 10.0 on this exact
box, and we have now done so: the ROCm 10.0.0 runtime is what we run in
production as of 2026-10-13 (the same 0.1.43 binary and source, only the engine's
`LD_LIBRARY_PATH` repointed at the 10.0.0 `libamdhip64`/`hsa-runtime` via the
serve config's `lib_dirs` - no rebuild). That is the runtime-only A/B the
caveat above asks for on the 7.2.3->10.0 axis: **0 fires in 1911 requests**,
against **2 in 1399** on 7.2.3 over the same window on identical hardware.
(Repointing at the 7.2.1 r9700 libs fires again, so it is the 10.0 libs, not
"a newer build".) A 7.14 midpoint would still separate "TheRock rebuild" from
"10.0 specifically", but 10.0 alone fixes it for us, so we are unblocked.

*(We carry two local clamps, both still unclamped upstream: `kv_q8.cu` and
`src/prefill/kernels.cu` `kv_append_kernel` write `amax / 127` to fp16 without a
clamp. They are on the int8-KV path and are not what closes #879 — flag if you
want them A/B'd off.)*

---

## POST B — target: issue #1569 (cross-ref #1705)

**Title/lead:** Same `exit code -6` on R9700 `gfx1201` (Linux, ROCm 7.2.3): 7 hangs
in 5 days, and `HSA_USERPTR_FOR_PAGED_MEM=0` does **not** stop them

Same GPU family and exit code as the OP here, on Linux. Reporting because #1705
(gfx1100) reports `HSA_USERPTR_FOR_PAGED_MEM=0` *ended* its hangs, and on this box
it does not.

### Setup

AMD Radeon AI PRO R9700 32 GB (`gfx1201`), single card; NixOS, kernel 7.2.9;
ROCm `clr`/`hipblaslt`/`rocm-runtime` **7.2.3**; Strata 0.1.41 → 0.1.42 → **0.1.43**;
Qwen3.8-Flash-Next UD-IQ4_XS native pack, `--max-context 262144 --kv int8
--kv-resident 32768 --spec 4 --resident-budget-gib 55`; env includes
`HSA_USERPTR_FOR_PAGED_MEM=0` and `LimitCORE=0` (dumps were 32 GB each).

### The hangs

Every one is identical: engine watchdog (#29) `SIGABRT`s after
`no progress for 60 s during a request (reading the prompt (batched):
waiting for the GPU (attention, router) at layer N of the prompt chunk from
token T)`, then within seconds amdgpu's MES fails `REMOVE_QUEUE`/`SUSPEND` and
the kernel does a **MODE1 reset** (`VRAM is lost due to GPU reset!`). Always
**prompt prefill**, never decode.

| when (BST) | eng | layer | token offset |
|---|---|---|---|
| 2026-10-09 23:20:21 | 0.1.41 | 43 | 105,771 |
| 2026-10-11 09:44:01 | 0.1.42 | 15 | 131,123 |
| 2026-10-11 10:53:33 | 0.1.42 | 27 | 119,199 |
| 2026-10-11 14:29:21 | 0.1.42 | 11 | 85,637 |
| 2026-10-12 01:13:49 | 0.1.42 | 19 | 140,142 |
| 2026-10-12 03:09:33 | 0.1.42 | 35 | 194,856 |
| 2026-10-13 12:07:34 | 0.1.43 | 19 | 61,928 |

`coredumpctl` confirms a `SIGABRT` at each timestamp (so the exit is the watchdog,
not a fault). **All seven are with `HSA_USERPTR_FOR_PAGED_MEM=0` set** (applied
2026-10-08) — i.e. the #750/#1705 workaround does not fix this instance.

Note `NRestarts=0` is misleading: `bin/strata-server` restarts the engine child
in-process, so systemd never sees the failure (worth not trusting when triaging).

### Question

Is this the same class as #1569 / #1705 / #1691, or a distinct one? And given
MKheru's ROCm-10 result on #879, has anyone tried running the hang reproducer on
ROCm 10.0.0 libraries? (Caveat: 10.0 is not simply "7.2 + two majors" — 8 and 9
were never released; the path was 7.2 stable → 7.9–7.14 preview → 7.14 TheRock →
10.0, so a 7.2-vs-10 A/B also changes the build system. A 7.14 midpoint would
isolate the runtime from the rebuild.) If both the NaN poison and these prefill
stalls are 7.2.x runtime behaviour, that would explain why
`HSA_USERPTR_FOR_PAGED_MEM=0` moved the gfx1100 case but not this one.
