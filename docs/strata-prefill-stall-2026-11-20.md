# Strata prefill stall — 2026-11-20 (R9700 / gfx1201)

**Status: OPEN, unresolved upstream.** The engine's own 60 s no-progress watchdog
(upstream issue #29) aborts long prompt reads: `exit -6`, the request returns
`done: 0 tokens … (error)`, and with a single serving slot every later request
queues behind it. Reproduced on **three engine builds** — 0.2.15 (0.1.61),
0.2.17 (0.1.63) — and **not** seen since reverting to 0.2.13.1+main-13eedf55
(0.1.59.1) at 16:24 on 2026-11-20 (that build ran 11-13 → 11-18 with zero hangs).

This file is the evidence pack, and the "Upstream issue" section at the end is a
ready-to-paste report.

---

## Environment

| | |
|---|---|
| GPU | AMD Radeon AI PRO R9700 32 GB, gfx1201 (HIP), 240 W cap (panel), `perf` auto/high both tried |
| Host | zen3-nixos, Ryzen 5950X, 94 GiB RAM, zram; kernel 7.2.11 (`amd_iommu=on`, `amdgpu.gpu_recovery=1`, `amdgpu.lockup_timeout=10000`, `amdgpu.vm_update_mode=3`, `ppfeaturemask=0xffffffff`) |
| Runtime | engine maps the store-built **ROCm 10.0.0** (`rocm10-runtime.nix`), not nixpkgs 7.2.x |
| Model | `qwen3.8-flash-next-unsloth-ud-iq4-xs-v31`, native pack + 4-shard UD-IQ4_XS v31 GGUF, DFlash2 draft (selq4), `--vision` |
| Run line | `--expert-cache auto --prefill auto --max-context 393216 --rope-scaling yarn --rope-scale 1.5 --kv int8 --kv-resident 32768 --resident-budget-gib 56 --expert-profile … --spec 6 --draft-conf 0.5` |
| Host config | `hosts/zen3-nixos/ai/strata.nix`, `strata-package.nix` |

## Symptom

Only **long multi-chunk prompt reads** (a full re-read of a 148–289 K-token
conversation; `cache_n: 0`). Warm/incremental requests (`prompt_n` tens to a few
thousand) never fail. Typical failing request:

```
[strata] reading the prompt: 7,022 of 269,677 tokens, 3 s so far
[strata] reading the prompt: 123,754 of 269,671 tokens, 39 s so far
[strata] reading the prompt: 123,754 of 269,671 tokens, 99 s so far
[strata] the engine stopped unexpectedly (exit code -6). The engine stopped itself because it
         had stopped making progress - a hang it caught …
[strata] done: 0 tokens in 103 s (no speed) (error, cancel=False)
```

All failure positions observed on 2026-11-20: **0, 13 134, 52 540, 53 909, 79 491,
123 754, 152 932, 182 126, 189 720, 211 296, 234 572** tokens; layers **18, 19,
20, 21, 22, 24, 26, 35, 43** (18–22 dominate). Hang rate today ≈ 50 % of big
reads; the same workload was clean 2026-11-13 → 11-18.

## The stall report says the GPU is holding work and the host is idle

Identical on 0.1.61 and 0.1.63:

```
strata serve: no progress for 60 s during a request (reading the prompt (batched):
  layer 22 of the prompt chunk from token 182126) - stopping the engine so the server starts it again (issue #29)
strata serve: stall report (engine 0.1.63): stage "…" for 60 s; 0 layers served since the last finished step
  VRAM free when this request began: 760 MiB
  the prompt's GPU work (GPU 0) was still running
  expert pool: epoch 101498, batch epoch 101498: 108 of 108 jobs claimed, 108 done; 15 of 15 workers parked, 15 sleeping
  host idle for 120434 ms
  threads waiting on the disk (state D): 0 of 80
  memory: 33034 MiB resident, 0 MiB in swap, 31867 MiB RAM available; 2224 major page faults so far
  GPU work paused by the graphics driver: 549 ms since the engine started, 19 ms in this request
```

- `VRAM free when this request began` was **760–788 MiB in every stall** (the
  expert cache `auto` fills the card and leaves 842 MiB at load).
- No ring timeout, no GPU reset, no MES failure, no VM fault, no overdrive
  failure in `dmesg` — the driver believes the queue is healthy.

## Live captures (both engine builds, 2026-11-20 16:15 and 16:19)

GPU, from `amd-smi` and the gpu-panel sysfs sampler, **during** the hang:

```
pwr=60-80 W (cap 240), sclk=2319 MHz, mclk=1258 MHz, util=100 %, mem_busy=0,
edge 48-53 °C, hotspot 54-58 °C, fan 1194 rpm
```

i.e. the card is **100 % busy at 1/3 of its power budget with no memory
traffic** — a kernel spinning, not computing. `power_dpm_force_performance_level`
was `high` in one of those captures, so `mclk 1258` — the DPM was *not* limiting.

Threads of the engine process (`/proc/<pid>/task/*/status`):

| build / env | threads in state `R` |
|---|---|
| 0.1.63, defaults | `strata-host`, `strata`, **`strata-issue`** |
| 0.1.63, `STRATA_PREFILL_ISSUER=0` | `strata-host`, `strata` (no issuer thread) |

With the issuer thread on, it was spinning in `prefill.cpp`:

```c
for (size_t idx = 0; idx < seq.size(); ++idx) {
    while (idx >= a_consumed.load(std::memory_order_acquire) + (size_t) m.ring) {
        cover(idx);
        if (a_stop.load(std::memory_order_acquire)) return;
        std::this_thread::yield();          // ← observed here
    }
    …
```

…i.e. waiting for the compute side to release a stage slot. With
`STRATA_PREFILL_ISSUER=0` the same request still hung (at 79 491 of 150 K), so
the copy ring is a *symptom*, not the owner.

## Ruled out (all with a control run)

| Hypothesis | Test | Result |
|---|---|---|
| Clock/power-cap fault | `power_dpm_force_performance_level=high`, `mclk` pinned 1258 | still hangs; the 96 MHz/80 W state is the *consequence* of a spinning kernel (mem_busy 0), and a healthy prefill pulls 237–250 W at 1258 |
| Accumulated GPU/SMU state | reboot 15:06 + OD table reset (`echo c > pp_od_clk_voltage` now passes silently, 0 overdrive errors that boot) | still hangs |
| Engine 0.2.15 specifics | bump to 0.2.17 / engine 0.1.63 | still hangs (and 0.2.17's own fixes for this class don't cover it) |
| Matrix-core QSA scorer (only runs > 28 672 tokens — the whole failing range) | `STRATA_SELECT_WMMA=0` | still hangs (189 720 of 284 K) |
| Copy-ring issuer handshake | `STRATA_PREFILL_ISSUER=0` | still hangs (79 491 of 150 K) |
| Mid-prompt checkpoints (`6 checkpoints` per 288 K read, 10 s gap at each) | `--prompt-cache-every 0` | same 10 s pauses at the same offsets, still hangs |
| Conversation-cache park overlapping the next read (3–5 GB host copy per turn) | `--conversation-cache-mib 0` | still hangs (53 909 of 158 K) |
| Disk / file tier | stall report: `0 of 80` threads in `D`; watchdog's IO allowance never engages | not it |
| Host RAM pressure | 20–31 GiB `MemAvailable`, 0 swap at every stall | not it |

## Reproduction notes

- **Synthetic prompts do not reproduce it.** 200 K / 270 K / 288 K tokens of
  `w000123456` filler (99.8 % expert-cache hit) ran at 3.0–3.3 K tok/s,
  repeatedly.
- **Real-text prompts do, intermittently.** A 288 K-token prompt built from this
  repo's own sources completed (3 002 tok/s); the next one (283 K) completed
  (2 990); a third (277 K) completed (3 010); a fourth (284 K) hung.
- **Separate performance finding:** every long read has a ~10 s gap in layer
  progress at fixed offsets (125 868 and 251 736 for a chunk of 31 467 ≈ 4× and
  8× the 32 768-cell KV ring). Across a 96 s read that is ~30 s of dead time.
  `STRATA_PREFILL_TIMING=1` puts `qsa select` at 16.3 % of prompt GPU time and
  `host: waiting for each chunk` at 24 s.
- The `--expert-cache auto` fill leaves ~760 MiB VRAM free, and that number is
  in every stall report. A driver-level eviction/retry deadlock is the
  remaining unexcluded mechanism.

## Current live configuration (2026-11-20 16:24)

- Engine reverted to **0.2.13.1+main-13eedf55 (0.1.59.1)** — zero hangs so far.
- `STRATA_WATCHDOG_S=180` kept as a net (a slow-but-finishing stall completes
  instead of failing the turn; a truly stuck one holds the single slot 3 min).
- Conversation cache left **off** (`--conversation-cache-mib 0`), expert profile
  back to the one 0.2.13.1 ships, mid-prompt checkpoints back on.
- The 0.2.17 port is in git history (`c905142`) and stashed in
  `/tmp/opencode/strata-package-0.2.17.nix` if we want it back.

---

## Upstream issue (ready to paste)

**Title:** R9700 (gfx1201): prompt read hangs the GPU — watchdog kills the engine
(exit -6) at layers 18–22, GPU 100 % busy / 0 memory traffic / ~60 W

**Body:**

> Qwen3.8-Flash-Next UD-IQ4_XS (native pack), R9700 32 GB, HIP, ROCm 10.0.0
> runtime, engines **0.1.61 and 0.1.63**, Linux, `--serve` with one slot.
>
> Long prompt reads intermittently hang. The engine's #29 watchdog fires after
> 60 s: `no progress for 60 s during a request (reading the prompt (batched):
> layer 22 of the prompt chunk from token 182126)`, then `exit -6` and
> `done: 0 tokens … (error)`. Positions we have hit: 0, 13 134, 52 540, 53 909,
> 79 491, 123 754, 152 932, 182 126, 189 720, 211 296, 234 572; layers 18–22
> dominate. Warm/incremental reads never fail; a full re-read of 148–289 K
> tokens fails about half the time on our box today.
>
> The stall report on both engines says:
>
> ```
> the prompt's GPU work (GPU 0) was still running
> expert pool: 108 of 108 jobs claimed, 108 done; 15 of 15 workers parked, sleeping
> host idle for 120434 ms
> threads waiting on the disk (state D): 0 of 80
> memory: 33034 MiB resident, 0 MiB in swap, 31867 MiB RAM available
> GPU work paused by the graphics driver: 549 ms in total, 19 ms in this request
> VRAM free when this request began: 760 MiB
> ```
>
> Sampled during two of the hangs: `socket_power 60–80 W` (cap 240),
> `gfx_activity 100 %`, `mem_busy 0`, `sclk 2319`, `mclk 1258` (perf level
> `high` in one capture, so DPM is not limiting), hotspot 54–58 °C. `dmesg` has
> **no** ring timeout, GPU reset, MES failure or VM fault. Trailing edge of the
> card is fine: healthy prefills pull 237–250 W at `mclk 1258`.
>
> Threads of the engine process, sampled live: `strata-host`, `strata` and
> `strata-issue` all in state `R`; with the issuer on it is parked in
> `prefill.cpp`'s `while (idx >= a_consumed.load() + ring) { … yield(); }`.
> `STRATA_PREFILL_ISSUER=0` does **not** fix it (still hangs, at 79 491 of
> 150 K); neither does `STRATA_SELECT_WMMA=0`, `--prompt-cache-every 0`, or
> `--conversation-cache-mib 0`.
>
> Not reproduced with synthetic prompts: 200–288 K tokens of repetitive filler
> (99.8 % expert-cache hit) always complete at 3.0–3.3 K tok/s; real-text
> prompts at 277–288 K complete about 3 times in 4 and hang otherwise.
>
> Two things we would find useful:
> 1. Whether the 60 s heartbeat is expected to cover *inside* a prompt chunk —
>    we see ~10 s gaps in layer progress at fixed offsets even on successful
>    reads (125 868 and 251 736 for a 31 467-token chunk ≈ 4× and 8× the
>    32 768-cell KV ring), i.e. ~30 s of a 96 s read.
> 2. Our `--expert-cache auto` leaves **760 MiB** VRAM free, and that exact
>    figure is in every stall report. If a driver-side eviction/retry deadlock
>    is plausible at that headroom, a documented minimum-free VRAM for the
>    prompt path (or `--expert-cache` guidance) would be worth a line in
>    docs/AMD_HIP.md.
>
> Engine 0.1.59.1 (0.2.13.1+main-13eedf55) has not reproduced it: our engine log
> shows zero `no progress` episodes from 2026-10-20 through 2026-11-17 under the
> same traffic, which is why we are back on it.

## Related upstream notes (0.2.15 "Known problems", for context)

> **Radeon gfx1201: DFlash2 chosen by hand can stall on the prompt** (11 of 50
> engines on 0.2.11). Auto picks MTP on these cards.
>
> **Radeon R9700 on Linux: one engine start stalled** on its first prompt and the
> driver reset the card (IQ3_S, 4 KiB memory pages). The engine stopped itself
> after 60 seconds without progress.

0.2.17 fixes that came closest to this class (none of them fixed our case):
HIP keeps the kernel's NUMA balancing off the engine's memory (#4866/#4867), a
first prompt over two chunks no longer ends the engine with `exit -6` (#5104
#5354 #5966 #6018 #6134), and a watchdog beat in the PLE reader (#4682).
