# Strata batching (`--batch` / `"parallel"`) on zen3-nixos: would two concurrent sessions be faster?

**Date:** 2026-10-15 · **Status:** analysis — **batching left OFF, no config change**
**Applies to:** `zen3-nixos` — Strata 0.1.44.1 (`hosts/zen3-nixos/ai/strata*.nix`),
Qwen3.8-Flash-Next UD-IQ4_XS on the R9700 (gfx1201, HIP), 94 GiB RAM.
**Related:** `docs/strata.md`, `docs/strata-hang.md`, `docs/strata-expert-helper.md`,
`docs/multi-gpu-inference.md`.

---

## TL;DR

- **Strata does support continuous batching.** `"parallel": N` in the run config →
  `--batch N` (alias `--slots N`) on the engine: up to N conversations decode in one
  verify window, one token (or one token + one MTP proposal with `--batch-mtp`) each.
  Opt-in since #465, engine side PR #559. Upstream doc: `docs/BATCHING.md`.
- **We are not running it.** The live run config has no `parallel` key and no
  `--batch` in `args`, and `GET /v1/status` says
  `"concurrency": {"serving": 1, "requested": 1}`. Two sessions today means one of
  them waits for the other to finish generating entirely.
- **For two sessions the answer is: better waiting, worse speed.** Batching buys
  time-to-first-token (modelled **10.9 s → ~4 s** for the second session) and pays
  for it in per-stream decode, because **batch slots carry no MTP drafts by
  default** — and our 54.8 tok/s *is* the draft path (236 of 348 proposals accepted,
  ~1.7 tokens per window).
- **The only variant with a measured single-card throughput *gain* is `--batch-mtp`**
  (+31 % to +39 % total, 2–4 clients, one GPU, RTX PRO 5000 — "a RX R9700 run too"),
  and it pays "only when the experts do not all fit in VRAM" — which is us (43 %
  resident). Counter-evidence: on a 2× R9700 **layer split** with all experts
  resident it measured **−21.9 %**.
- **The blocker is VRAM: 232 MiB free** (32392 / 32624 MiB). Slot sessions come
  straight out of the expert cache, and decode speed on this model is almost
  entirely hit-rate-driven. So enabling it trades the thing we are buying the card
  for (55 tok/s on one stream) for the thing we rarely need (a second stream).
- **Recommendation: leave it off at 2 sessions; revisit at 3+ concurrent** (Pi +
  subagents + Recallium background), and if tried, try `--batch 2 --batch-mtp` and
  read the `strata batch:` lines, don't guess.

---

## 1. What the feature actually is

Read off the pinned source, not the changelog:
`/nix/store/aa99cjacdlwdxsbi9i1p20i4k2ffvf24-296b59d2f73c8f04a805df29c2fa97655adace78.tar.gz/docs/BATCHING.md`
(rev `296b59d2` = 0.1.44.1, the `strata` flake source).

| Knob | What it does |
| --- | --- |
| `"parallel": N` → `--batch N` / `--slots N` | up to N conversations hold batch slots; more requests wait for a free one. Each slot gets its own session (GDN recurrence, QSA K/V + indexer, PLE history) carved like the stage's own. **2..8** — `PARALLEL_MAX = 8` (`serve/server.py:2606`: "the engine's batch window holds at most 8 rows (`kVerifyMaxT`); `--batch-mtp` waves more through it"). |
| `--batch-mtp` (or `STRATA_BATCH_MTP=1`) | needs `--mtp` **and** `--spec`: each slot also verifies **one** MTP proposal per window. Costs VRAM per slot for private draft state. |
| `--batch-groups G` | **layer split only** — the N slots in G groups pipelined through the GPUs. Not applicable to a single card. |

Serve-layer plumbing (`serve/server.py`): `parallel_args()` at **:2609** (returns
`[]` if `--batch`/`--slots` is already in the args, so an explicit flag wins);
the engine's real count is read back from `INFO batch_slots=N` at **:902** and
surfaced as `concurrency.serving`; `generate_batched()` at **:1478** is the request
path.

Behaviour that matters operationally:

- **A request alone never enters a slot** — it runs the solo path (with MTP drafts,
  the fastest stream). When a second arrives, the first is `STOP`ped and re-homed
  into a slot with its prompt + what it generated (the prompt cache holds exactly
  that, nothing is re-read). A slot left alone goes back to solo (≤ 2× per request;
  `STRATA_PARALLEL_SOLO=0` disables).
- **Each slot doubles as a conversation cache** — the next turn of that conversation
  is copied back into it (~50-60 ms) instead of re-reading history.
- **Prefill and decode interleave**: admissions happen through the normal prompt
  path, and **the slots decode between the prompt's chunks** — after each chunk
  (`--prefill`, 2048-8192 tokens) they decode for half as long as the chunk took
  (`STRATA_BATCH_DECODE_SHARE`, default 0.5). Plus cooperative preemption `BYIELD`
  (#656): a long read gives way at a chunk boundary to a waiting prompt less than
  half as long (≤ 2× per request).
- Observability: `/metrics` → `live.slots` (idle / reading / decoding, tokens,
  tok/s) and `live.running`; `GET /v1/status` → `concurrency.serving`; the engine's
  `strata batch:` line shows per-window rows, ms, and how many routed entries came
  from the VRAM tier vs the PCIe share vs the CPU.
- Engine protocol: `BGEN`/`BGENI` (admit into a slot), `BADM`, `BT <slot> <id>`,
  `BDONE`, `BSTOP`, `BYIELD`/`YIELDED`, `INFO … batch_slots=N`.

## 2. Proof of the current state (2026-10-15)

```sh
systemctl show strata -p ExecStart --value      # strata-server --engine strata --config <store>/strata-ud-iq4-xs.json
grep -o '"[a-z_-]*"' /nix/store/yp52vi1p70vkbinyd46k5w4029w93ify-strata-ud-iq4-xs.json | sort -u
curl -s http://127.0.0.1:8080/v1/status
```

- Engine **0.1.44.1**, unit `strata` up since **2026-10-15 17:40:35 BST** (so the
  0.1.43 → 0.1.44.1 switch noted as "not yet deployed" in `AGENTS.md` has happened).
- `args` = `--pack … --native … --expert-profile … --expert-cache auto --prefill auto
  --spec 4 --spec-min-p 0.5 --mtp /home/cjdell/Strata/mtp/rt --max-context 393216
  --rope-scaling yarn --rope-scale 1.5 --kv int8 --kv-resident 32768
  --conversation-cache-mib 16384 --conversation-cache-slots 12
  --conversation-cache-min-tokens 2048 --resident-budget-gib 55`.
  **No `--batch`, no `--slots`, no `parallel` key** → `parallel_args()` returns `[]`.
- `/v1/status`: `concurrency {serving: 1, requested: 1}`, `activity {requests: 339,
  in_flight: 0}`, `machine.gpu {used_mib: 32392.0, total_mib: 32624.0, util_pct: 100,
  power_w: 241.0}`, `machine.ram {used_gib: 57.9, total_gib: 94.2}`.
- Last request (`last_timings`): `cache_n 62038`, `prompt_n 1072`,
  `prompt_ms 2096.3` (511 tok/s), `predicted_n 368`, `predicted_ms 6718.3`
  (**54.8 tok/s**), `draft_n 348`, `draft_n_accepted 236`.

That last row is the whole argument in one line: **a typical turn here is 2.1 s of
prefill + 6.7 s of decode**, and 62 K of it is cache reuse, so the conversation cache
(`--conversation-cache-slots 12`) is already doing the multi-session work. What
batching changes is only the 6.7 s.

## 3. What a slot costs here

| Cost | Upstream figure | On this box |
| --- | --- | --- |
| VRAM per slot session | **0.56 GiB** at 32K ctx with 8-bit KV, "more with a longer context unless the KV cache streams" | We pass `--kv-resident 32768`, so ~0.56 GiB stays in VRAM (the resident 32K window) — taken **out of the expert cache** (engine: `--batch %d: the slot sessions take %.2f GiB of VRAM … that the expert cache would otherwise hold`). |
| Pinned RAM per slot | "each slot's whole KV cache takes pinned RAM — 1.6 GB at 128K" | int8 KV is 12,672 B/token → **4.64 GiB at the full 393216 ctx** per slot. 36 GiB of RAM is free, so affordable, not free. |
| `--batch-mtp` extra | "the two slot drafters cost 35 to 110 expert-cache slots on the last GPU (50 MiB of private state each)" | ~0.1-0.2 GiB of cache for 2 slots, on top of the sessions. |
| Free VRAM right now | — | **232 MiB.** The engine allocates slot sessions at startup, so it fits by shrinking the expert cache; it never OOMs, it just decodes slower. |

Why the cache shrink is the expensive part — decode on this model is hit-rate
money (`docs/strata.md` "UD-IQ4_XS"):

| Pack | Expert cache | Hit rate | Decode |
| --- | ---: | ---: | ---: |
| UD-IQ4_XS (live) | 10,679 slots | 90-93 % | **48-57 tok/s** |
| IQ3_S | 13,104 slots | 92-97 % | 62-68 tok/s |

0.56 GiB is ~2.3 % of the 24.87 GiB tier, i.e. a couple of hundred slots — small,
but it comes off the *marginal* slots that carry the last few percent of hit rate.
(It does **not** change the `STRATA_ROUTE_TAIL_SKIP` regime: that stays off only
from 90 % of experts resident and we sit at 43 %.)

## 4. The measurements that matter

**Single card, experts partly on CPU** — RTX 5070 12 GB, Ryzen 5 7600, 64 GB DDR5,
Q2_0, 32K ctx, C requests at once, 800-word essays, 256 tokens/answer, greedy,
median of 3 rounds (`BATCHING.md` "Measured"):

| Concurrent | Setting | Total tok/s | Per request | First token: median / last |
| ---: | --- | ---: | ---: | --- |
| 1 | one at a time | 74.3 | 83.6 | 0.4 s / 0.4 s |
| 1 | `"parallel": 2` | 67.3 (**−9 %**) | 74.8 | 0.4 s / 0.4 s |
| 1 | `"parallel": 4` | 57.9 (−22 %) | 63.8 | 0.4 s / 0.4 s |
| 2 | one at a time | 71.6 | 77.3 | 2.1 s / **4.1 s** |
| 2 | `"parallel": 2` | 61.0 (**−15 %**) | **32.6** | 0.5 s / **0.9 s** |
| 2 | `"parallel": 4` | 54.6 (−24 %) | 28.7 | 0.6 s / 0.7 s |
| 4 | one at a time | 70.7 | 79.6 | 6.0 s / **11.2 s** |
| 4 | `"parallel": 2` | 61.2 (−13 %) | 32.2 | 4.5 s / 9.3 s |
| 4 | `"parallel": 4` | 63.1 (−11 %) | 16.9 | 1.0 s / **1.8 s** |

Read it as: **the slots buy waiting time, not speed.** The fourth of four requests
starts after 1.8 s instead of 11.2 s, but everything decodes 11-24 % slower, and a
request *alone* loses 9-24 % purely to the smaller expert cache. Upstream's own
explanation: a 4-row window reads ~24 CPU experts per layer against ~8 for one
(`strata batch:`: 54 ms per 4-row window vs ~20 ms per 1-row window).

**Single card, `--batch-mtp`** — "RTX PRO 5000 owners measured **+31 % to +39 %
total throughput with 2 to 4 clients on one GPU (a RX R9700 run too)**". This is
the one number in the doc that argues for turning it on, and the caveat attached to
it is "it pays only when the experts do not all fit in VRAM" — our situation.

**Where it is a trap** — 2× R9700 layer split, all experts in VRAM: `--batch-mtp`
**80.2 → 62.7 tok/s (−21.9 %, 0/5 pairs faster)** against the pipelined default.
Same silicon, opposite sign, so the RDNA4 result is workload-dependent and worth
measuring before trusting either number.

**Where it genuinely scales** — needs multiple cards:
`--batch-groups auto` with 8 clients, total tok/s vs one group: **4× R9700 166 vs
86**, 2 GPUs 109 vs 78, 3 GPUs 110 vs 78. And a 4-GPU split (4× 16 GB, PCIe Gen3,
IQ3_S, `--batch 8 --batch-groups 4 --trim-stage-weights`, 400 tokens, temp 0.7):
1 req → 123 tok/s solo; 2 → 57 each / 113 total; 4 → 51 each / 205 total;
8 → 45 each / **360 total**. Not available on this box — the second slot trains at
Gen1 x2 (`docs/strata-expert-helper.md`) and mixed-vendor helpers are unsupported.

## 5. Modelled for our turn shape

Two sessions, each like the live `last_timings` (2.1 s prefill + 6.7 s decode at
54.8 tok/s = 8.8 s/turn):

| | today (`serving: 1`) | `--batch 2` (no drafts, ~32 tok/s/stream) |
| --- | --- | --- |
| Session A first token | 2.1 s | 2.1 s |
| Session B first token | **~10.9 s** (waits for A entirely) | **~4 s** (admission interleaves with A's decode) |
| Per-stream decode | 54.8 tok/s | ~30-35 tok/s (estimate, see caveat) |
| Both finished | ~17.6 s | ~13.6 s |

The ~32 tok/s is **transplanted from the RTX 5070 table, not measured here** — it is
the right order of magnitude (a 2-row window without drafts vs a 5-position solo
window with them) but our hit rate is far better than a 12 GB card's, so treat it as
a pessimistic bound. The direction is not in doubt: **B stops dead-airing, A gets
visibly slower while they overlap, aggregate throughput is roughly flat.**

## 6. Limits that would bite us specifically

- **No repetition / frequency / presence penalties in batch windows.** Any client
  that relies on them silently loses them the moment a second request overlaps.
- **Batch windows carry no MTP drafts by default.** With `--spec 4` and 68 % draft
  acceptance, this is the dominant cost — it is what `--batch-mtp` exists to fix.
- **Admissions are one at a time**: two fresh 100 K prompts are still read back to
  back (~80 s each at ~1,250 tok/s). What improves is that a decode no longer
  freezes for the whole of another request's prefill.
- **A prompt shorter than one chunk is read in one piece** (the slots wait for it);
  a read gives way only at a chunk boundary, and not for pictures.
- **Greedy output is only bit-equal to solo with** `STRATA_IQ_MT_MIN=1`,
  `--pcie-frac 0`, `--adapt-every 1000000`, `--no-prefill-borrow`. With defaults the
  texts stay coherent but drift apart — relevant to `docs/strata-degeneration.md`
  debugging, where we compare outputs between runs.
- **The adaptive expert tier does not run in pipelined `--batch-groups` windows**
  (N/A on one card, but it means the multi-GPU numbers above are not comparable).
- **`#1603`** — a queued request could wait forever on slot bookkeeping (fixed in
  0.1.42: claims/reaping of orphaned slots). `docs/strata-hang.md:186` records that
  **our single-slot setup is exactly what never hits it**. On a box with the #29
  hang-watchdog history, turning on slots opens that surface again.
- `session files do not support --batch (parallel requests)` — the engine refuses
  session save/load alongside batching (we don't use `--session-save`, so no impact).

## 7. If you do turn it on

One line in `hosts/zen3-nixos/ai/strata.nix` — either `parallel = 2;` in the
`configFile` attrset (server.py appends `--batch 2`), or explicitly in
`engineArgs` (`parallel_args()` steps aside when it sees `--batch`):

```nix
"--batch"
"2"
"--batch-mtp"      # restores one MTP proposal per slot; needs --mtp + --spec (we have both)
```

Then `sudo nixos-rebuild switch --flake .` (autoRollback is commented out on
zen3-nixos — **no `nixos-confirm`**). The switch restarts the service and the model
load takes ~30 s.

Verify, don't assume:

```sh
sudo grep -a "batch_slots\|slot sessions take\|batch-mtp\|batch window holds" /var/lib/strata/strata.log | tail
curl -s http://127.0.0.1:8080/v1/status | grep -o '"concurrency":{[^}]*}'
curl -s http://127.0.0.1:8080/metrics | grep -E "live|slots"
```

- `INFO … batch_slots=N` — **the engine may run fewer than asked, or none**, when
  they don't fit; server.py prints "`N` asked, the engine runs …" when it differs.
- `--batch 2: the slot sessions take X GiB of VRAM … that the expert cache would
  otherwise hold` — read X, then compare the `expert cache N slots` line against the
  10,679 of the current pack to see what you paid.
- Drive two streams and watch `strata batch:` (rows, window ms, VRAM/PCIe/CPU split)
  and `/metrics` `live.slots`. Upstream's own harnesses if you want exactness:
  `tools/batch_test.py`, `tools/batch_interleave_test.py`, `serve/test_parallel.py`
  (the last needs no GPU).

Rollback is deleting the line and switching again. Nothing about it is sticky.

## 8. Verdict

**Two sessions: leave it off.** The queue costs ~9 s of second-session latency per
turn, the conversation cache already removes the re-read cost of alternating chats,
and the fix costs expert-cache slots on a card that has 232 MiB of VRAM left — on a
model whose entire value here is 55 tok/s on one stream.

**Revisit when concurrency is actually 3+** (Pi + its subagents + Recallium
background processing all wanting the GPU), and then go straight to
`--batch 3 --batch-mtp` rather than plain `--batch 3`: at 4 concurrent the 5070
table shows `parallel: 4` beating `parallel: 2` on aggregate (63.1 vs 61.2) while
crushing the wait (1.8 s vs 9.3 s for the last request to start), and `--batch-mtp`
is the only variant ever measured as a net gain on one card.

The real fix for concurrency on this box is the one `docs/strata-expert-helper.md`
already ruled out: a second card and `--batch-groups`, where 4× R9700 doubles
aggregate throughput (166 vs 86 tok/s). The B550's free slot is the wall, not the
software.

## 9. Not to be confused with

- **`--conversation-cache-slots 12`** (already live) = **prefix/conversation
  parking** in host RAM: N conversations' K/V + checkpoints kept so a follow-up turn
  doesn't re-read history. Costs RAM, not VRAM. It is why alternating chats are
  already cheap; it does not let two requests decode at once.
- **`"replicas": N`** (`serve/replicas.py`) = **data-parallel**: N independent
  engines on separate GPU groups behind one HTTP front, cost-routed so a
  conversation returns to the replica holding it. Needs multiple cards.
- **llama-swap's `--parallel 1`** = llama.cpp's own slot count, a different engine
  (llama-swap is off on this box; Strata replaced it).

## Sources

- Upstream `docs/BATCHING.md`, `docs/MULTI_GPU.md`, `docs/AI_SETUP.md` at rev
  `296b59d2f73c8f04a805df29c2fa97655adace78` (v0.1.44.1), read from the flake source
  in the store:
  `/nix/store/aa99cjacdlwdxsbi9i1p20i4k2ffvf24-296b59d2f73c8f04a805df29c2fa97655adace78.tar.gz/`
- `serve/server.py` in the built package:
  `/nix/store/yrxmsd6ss59ni7874xcri0mn9rf2kr8b-strata-0.1.44.1/share/strata/serve/server.py`
  (`parallel_args` :2609, `PARALLEL_MAX` :2606, `generate_batched` :1478, slot
  bookkeeping :901-940)
- `strings` of `/nix/store/yrxmsd6ss59ni7874xcri0mn9rf2kr8b-strata-0.1.44.1/bin/strata`
  for the `--batch` / `--batch-mtp` / `--batch-groups` help text and the runtime
  warnings.
- Live state: `systemctl show strata -p ExecStart`, the run config
  `/nix/store/yp52vi1p70vkbinyd46k5w4029w93ify-strata-ud-iq4-xs.json`, and
  `curl -s http://127.0.0.1:8080/v1/status` (2026-10-15).
- Repo: `docs/strata.md` (pack/cache slot and tok/s tables), `docs/strata-hang.md`
  (#1603, single-slot setup), `docs/strata-expert-helper.md` (second-GPU walls).
