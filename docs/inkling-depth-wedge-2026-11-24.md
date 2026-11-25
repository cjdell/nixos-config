# Inkling-2-Mini on strata-inkling 0.2.21 (HIP, gfx1201): the 81–122K depth wedge

**Status (2026-11-25 00:05):** open, engine-side. Reported upstream as
`[Engine] strata-inkling 0.1.67 (HIP, gfx1201/R9700): 81-122K prompt read
completes with no first token, engine spins`. One variable changed the behaviour:
`--chunk 512` (instead of 2048) completed an 82K cold read that had wedged on
2048 minutes earlier. Single observation so far — treat it as a lead, not a fix.

## The signature

A large prompt (81–122K) is admitted when a *different* large context is already
resident (prefix match 0, so the engine must replace it). Then:

1. the read is reported complete (`81,042 of 81,042 tokens`), and at chunk 2048
   the *first* chunk alone takes ~190 s (`2,048 of 81,042 tokens, 198 s so far`);
2. the remaining ~79K tokens are then "read" in 10 s — **7,900 tok/s, i.e. it
   did not read them**;
3. no first token follows, for 230–300 s and counting;
4. the engine is spinning, not waiting: 4 threads, two in `R`, GPU at 100 % GFX
   / 119–145 W / `umc` 10–27 %, no amdgpu error, no ring timeout, no Xid, no
   watchdog kill;
5. VRAM is NOT full — 9.4 GiB free of 31.9 GiB, GTT at 95–99 MiB (no host spill).

A second, different signature appeared with two concurrent large requests
(`parallel`/slot routing, two ~110K contexts against a 163,840 pool): both reads
complete and neither decodes. That one is excluded by `--parallel 1` in the
serve config, because this box runs one conversation — but it is the same class
of "nothing progresses while the card is busy".

## Environment

| | |
| --- | --- |
| Card | Radeon AI PRO R9700 32 GB, `1002:7551` (Navi 48, gfx1201), BAR0 32 GB, 31.9 GiB usable |
| Console GPU | RX 580 `1002:67df` (excluded: `HIP_VISIBLE_DEVICES=0`; only the R9700 is HIP-visible) |
| Host | NixOS 26.11, kernel 7.2.11, 94 GB RAM, no swap pressure (11 GiB used) |
| Strata | 0.2.21 (source build), engine `strata-inkling-0.1.67` |
| Build | HIP `-DCMAKE_HIP_ARCHITECTURES=gfx1201`, nixpkgs ROCm 7.2.x headers/libs, `hipblaslt` present |
| Runtime | **ROCm 10.0.0 (TheRock) lib dir prepended to `LD_LIBRARY_PATH`** — an unrelated workaround for a Flash-Next bug, see "Deviations" |
| Weights | `Inkling-2-Mini-SQ-20.strata` 19,346,685,952 B `0bbfd523…` (also reproduced on Unsloth `UD-Q4_K_XL.gguf` 17,629,760,736 B `e6427665…`) |
| Vision | `Inkling-2-Mini-Vision.strata` (0.64 GB), on |
| Drafter | `mtp.safetensors` present, `--draft off` |
| Serve flags | `--max-context 163840 --kv fp8 --chunk 2048|512 --vision … --dspark …` |

## What was tried, and what it did

| # | weights | KV | chunk | slots | prompt | held before | result |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | GGUF UD-Q4_K_XL | fp16 | 2048 | 2 | 2 × ~106K | — | wedge, both streams stall (212K tokens vs 164K pool) |
| 2 | GGUF | fp16 | 2048 | 2 | 116K | 115K | `reused: 0` every turn, prefill 128,783 ms, 22 t/s |
| 3 | GGUF | fp8 | 2048 | 2 | 88,642 | 139,365 (prefix 0) | routed to the *other* slot, 0 progress, 73 s+ |
| 4 | GGUF | fp8 | 2048 | 2 | 108,311 + 109,579 | — | both reads complete, no first token, 304 s |
| 5 | GGUF | fp8 | 2048 | 1 | 109,748 | 109,579 | read complete `107,605/107,605`, no token, 231 s+ |
| 6 | **SQ-20** | fp8 | 2048 | 1 | 81,865 | 83,662 (prefix 0) | chunk-1 stall 190 s, then 79K "read" in 10 s, no token, 285 s+ |
| 7 | **SQ-20** | fp8 | **512** | 1 | 82,454 | 83,662 (prefix 0) | **completed**: prefill 155,365 ms (532 tok/s), out 826, next turn 24.8 t/s |

Notes on the table:

- Changing the pack format (GGUF → native `.strata`), the K/V dtype (fp16 →
  fp8), the slot count (2 → 1) and the arena size did **not** move the failure.
  Only the chunk size did.
- Under `--parallel 1` the engine is started without a `--parallel` flag at all
  (the serve layer only passes it for `> 1`), so its own default applies.
- Prefix reuse works very well when it applies: `reused: 118,162`, prefill
  6,067 ms vs 157,253 ms for the same conversation cold, and 99.9 % on
  agent turns. Every wedge involved a prompt that could not reuse the resident
  context.

## Evidence

Chunk 2048, the 82K wedge (2026-11-24 23:52):

```
[strata] pick: prompt 81865 tokens, held [83662], busy [False], prefix [0], -> slot 0
[strata] reading the prompt: 2,048 of 81,042 tokens, 198 s so far
[strata] reading the prompt: 81,042 of 81,042 tokens, 208 s so far      <- 79K in 10 s = 7,900 tok/s
[strata] reading the prompt: 81,042 of 81,042 tokens, 238 s so far      <- and then nothing
```

Engine process at that moment (`/proc/<pid>/task/*/stat`), 285 s in:

```
2892443 R   <- main thread
2892446 R
2892447 S
2892477 S
```

GPU / memory at the same moment:

```
amd-smi: gfx 100 % util, umc 10 %, 2,287 MHz, 119 W      (other wedges: umc 27 %, 145 W)
vram 23,262 MiB used / 9,362 free, gtt 99 MiB
```

Ring sizing, the only thing that changed the outcome:

```
--chunk 2048:  [ink-hip] SWA KV ring 3072 positions (window 1024, forward_batch span cap 2048)
--chunk 512:   [ink-hip] SWA KV ring 1536 positions (window 1024, forward_batch span cap 512)
```

Chunk 512, the same prompt and the same held context, ~4 minutes later:

```
prompt=82,454  reused=0  prefill=155,365 ms  out=826  (stop)      <- 532 tok/s cold, no stall
next turn: prompt 83,285, generating at 24.8 tok/s
```

## Analysis

- **The read is being skipped, not completed.** 79,000 tokens in 10 s on a card
  that measures 530–690 tok/s at this depth is ~14× the possible rate. So the
  engine decided the prompt was already resident, then produced no token. That
  points at residency/KV bookkeeping rather than kernels: the decode step waits
  on state that was never armed for the new prompt.
- **The stall is one chunk wide.** At `--chunk 2048` the first chunk alone takes
  190 s and everything after it is skipped. At `--chunk 512` the read proceeds
  at ~512 tokens / 2 s (~570 tok/s) with no stall, and the request completes.
- **The ring is exactly at its edge at 2048.** The engine sizes the SWA ring as
  `window 1024 + chunk`, so `chunk 2048` makes the forward-batch span (2,048)
  *larger* than the window term; at 512 the span sits below the window. If the
  span is what indexes the ring during the replace path, 2048 is the edge case.
- **It is not memory pressure.** 9.4 GiB free, GTT at noise, one slot, one
  request. Wedges also reproduced with 12 GB free earlier in the evening.
- **The GPU spins rather than idles** (100 % GFX, 119–145 W, 10–27 % umc, no
  amdgpu error), which distinguishes it from the CUDA RTX 5090 report (#6605,
  GPU idle) and matches "a kernel is running, but no progress is being made".

## Related upstream issues

- **#6605** — Inkling-2-Mini on CUDA/RTX 5090: prefill hangs above ~20–27K, GPU
  *idle*, no token. Same family, different backend and different GPU state.
- **#6004** — prefill hangs on the *second* prompt chunk at any size (Windows,
  sm_120). Chunk-boundary class; ours stalls on the first chunk instead.
- **#6076** — gfx1201 `--verify` timed out at layer N at ~120K context.
- **#6420** — the neighbouring Flash-Next engine on this same card: long prompt
  read spins the GPU until the #29 watchdog kills the engine. Our case does
  *not* get watchdog-killed; it hangs indefinitely with no `exit -6`.
- **#6590 / #6792** — sm_75 / 12 GB fit-plan failures; not this.

## Deviations from a stock install (ask us to A/B any of these)

1. **Runtime ROCm 10.0.0** (TheRock store build) is prepended to the engine's
   `LD_LIBRARY_PATH`, ahead of the 7.2.x libs the Nix build RUNPATHs. This is an
   inherited workaround from the Flash-Next lane (#879 poisoned-context class:
   2/1399 requests on 7.2.3 vs 0/1911 on 10.0.0). We can re-run the 82K case
   with the build's own 7.2.x libs if that is preferred.
2. **The serve layer is patched** — five Python-only diffs against
   `share/strata/serve/server.py`: per-slot prefill progress + a request-table
   decode rate; an admission guard (`does_not_fit`) for the two-slot case; a
   `pick:` routing trace; "protect slot 0's conversation only while the new
   prompt fits beside it"; and a phase label that stops calling a generating
   request "reading the prompt". **The engine binary itself is unmodified** —
   the spin is in `strata-inkling`, and we can reproduce on a stock serve layer
   on request.
3. Serve config has one slot (`concurrency.serving: 1`) and we never pass
   `--parallel` to the engine (the serve layer only forwards it for `> 1`).

## Open questions

1. Is there a residency/bookkeeping invariant we can check from outside (an env
   var, a `/v1/status` counter, a trace) that would say why the read was
   skipped?
2. Is `--chunk 2048` expected to work at 81K on gfx1201, or is
   `span cap == ring` a case that must be avoided? If the latter, the launcher
   could refuse it (or clamp it) rather than spinning.
3. Should the engine have caught this itself — the Flash-Next serve has a
   no-progress watchdog (#29). Here nothing fired, so a wedged request holds
   the single slot forever.

## What to hand over

`/var/lib/inkling/collapse/*.json` (periodic samples of every wedge, with the
serve/slot state and the ring buffer of live counters) can be attached on
request.
