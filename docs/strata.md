# Strata on zen3-nixos (Qwen3.8-Flash-Next)

Status: **live on UD-IQ4_XS** since 2026-10-09 19:23 (IQ3_S from 2026-10-06,
IQ3_XXS before that). `ai.strataModel` switches pack in one line, and IQ3_S is the
faster of the two (~20 % on decode) — see "UD-IQ4_XS" below. Strata
(`github.com/Niko1221/Strata`) is the engine that runs the ~84-94 GB Qwen3.8-Flash-Next
on the 32 GiB R9700 that llama.cpp could only do at ~6.5 tok/s. It
replaces llama-swap on this box (see "Why llama-swap is off" below). This doc
records the install (which is half hand-prepared outside Nix), the config, and
the measured context / memory ceilings that were the point of the exercise.

**Image input is live** since 2026-10-15 22:09: `strata-vision` (mtmd, CPU encoder)
+ the ISTA mmproj, ~5 s to encode a picture, text output unchanged — see
"Vision (image input)" below.

**Concurrency:** the service runs **one request at a time** (`/v1/status` →
`concurrency.serving: 1`). Strata's batching (`"parallel"` / `--batch`, `--batch-mtp`)
is available and deliberately **not enabled** — on this card it buys second-session
waiting time and costs expert-cache slots and the MTP draft path. Analysis, the
upstream measurement tables and the numbers to watch if that changes: [`strata-batching.md`](./strata-batching.md).

## IQ3_XXS -> IQ3_S (2026-10-06)

We moved to the **highest** GSQ-RCO quant, IQ3_S (3.50 bpw non-uniform), from
IQ3_XXS (3.00 bpw). Only shard 1 differs: shard 2 is the 26.82 GiB
`per_layer_token_embd` (PLE) table and is **byte-identical across every GSQ-RCO
quant** (LFS sha256 `316b46f3…`), so it is hardlinked beside the IQ3_S shard and
read from disk either way.

| | IQ3_XXS | IQ3_S |
| --- | ---: | ---: |
| shard 1 (experts+dense) | 43.81 GiB | 51.05 GiB |
| shard 2 (PLE table) | 26.82 GiB | 26.82 GiB (identical) |
| experts loaded to RAM | 39.97 GiB | **46.84 GiB** |
| VRAM expert cache | 15764 slots | **13103 slots** (24.87 GiB) |
| decode cache hit rate | 96-98 % | **97.2-97.9 %** |
| engine RSS | ~46 GiB | **~51 GiB** |

The repack is `scripts/repack-strata-iq3s.sh` (verifies the shard sha, derives
the engine python from `.#strata`, materialises the pinned llama.cpp `gguf-py`,
runs `tools/iq_pack.py` -> `/home/cjdell/Strata/pack/iq3s`). `conversions.json`
reports `tensors: []` - the GSQ-RCO file is already in the engine's read form,
no `--compat-bf16` needed. The next rungs up are Unsloth's UD-* family
(UD-Q3_K_XL 90 GB, UD-IQ4_XS 94 GB, UD-Q4_K_XL 111 GB). UD-Q4_K_XL is
`"nvidia_only": True` in `setup.py:220`, so it is not an option on this box at
all; UD-IQ4_XS is analysed under "UD-IQ4_XS" below. (Nothing "squeezes the PLE
page cache": the PLE table is read with `--ple-io direct` — the default,
`generate.cpp:374` — unbuffered from NVMe, so it never competes for RAM.)

When IQ3_S is trusted, reclaim the old files with
`scripts/cleanup-strata-iq3xxs.sh --yes` (~46 GB: shard 1 and the iq3xxs pack;
shard 2 is a hardlink, so unlinking it frees nothing). It refuses unless the
engine is live and serving IQ3_S, and defaults to a dry run.

Upstream pinned: **v0.1.42**, rev `61b3fb5dd3f1e8ec09cf7e4e05208bc6d3c46406`
(`hosts/zen3-nixos/ai/strata-package.nix`), updated 2026-10-10 from v0.1.41
(`fb58e0dbc8399662c0e47c76578c6e878b14f6cf`). It builds its own ggml from a
pinned llama.cpp (`3cf03257f219afbe7334045ff7c6a06ac68c627d`) — **unchanged by
0.1.40 through 0.1.42** (`setup.py:166 LLAMA_CPP_COMMIT`), so
`strata-package.nix`'s `llama` fetch stays as it is.

## 0.1.40 / 0.1.40.1 (updated 2026-10-06)

Built and verified on this box (`nix build .#strata` ->
`/nix/store/vl353xnf6ccdlckjs2mm8j428s6zp28s-strata-0.1.40.1`, HIP/gfx1201,
`STRATA_PREFILL_MMQ=ON`, build phase 2 min 8 s). Not yet switched on the live
service — see "Deploy" at the bottom.

What actually changed for us (read off the two trees, not the changelog):

- **The two q8_1 clamps our 0.1.39 build carried are fixed upstream** ("the fused
  SwiGLU q8_1 quantizers keep their scale finite"): `native_mmvq.cu:172`
  (`native_swiglu_quantize_q8_1_kernel`) and `iq_kernels.cu:3342` (the fused
  gate/up block store) now use `q8_1_finite/q8_1_quant/q8_1_ds`. Those two
  `substituteInPlace` clamps are **removed** from `strata-package.nix` — their
  target strings no longer exist and `--replace-fail` would fail the build. The
  int8-KV clamps (`kv_q8.cu:55`, `prefill/kernels.cu:1340`) are **still ours**:
  upstream still writes `amax / 127` to fp16 unclamped there. Details:
  [`strata-degeneration.md`](./strata-degeneration.md).
- **`#871`**: the residency-table upload waits for its own copy before the
  verifier reads it, the 100 %-resident verify graph runs only while every expert
  is in VRAM, and a stale plan now fails the window (`verify.cpp`:
  `"verify: the all-resident plan met an expert that is not in VRAM …"`) instead
  of printing `!!!!`. Upstream could **not** reproduce #879 and asked both
  reporters to retry on 0.1.40.
- **HIP decode**: `sh_stream_on()` (the shared-expert stream fork) is new in
  0.1.40 and returns **false under `STRATA_USE_HIP`** by default — "brings decode
  back to 0.1.38 speed" (#826, #816). `STRATA_SH_STREAM=1` re-enables it.
- **Live switch, 2026-10-06 14:39 BST** (`/nix/store/vl353xnf6ccdlckjs2mm8j428s6zp28s-strata-0.1.40.1/bin/strata`,
  unit `strata`, engine pid 506234): experts loaded 39.97 GiB at 3.33 GiB/s (18 s),
  GPU expert cache 15,558 experts / 25.24 GiB, and on real agent traffic
  **56–60 tok/s** decode (was ~41 tok/s on 0.1.39) with 94–98 % expert-cache hit.
  The first request re-read a 45,073-token prompt in 29 s (~1,550 tok/s), so the
  cache rebuild cost one turn, not a regression. No `verify: non-finite logits` fire
  so far on 0.1.40.1.
- **gfx1151 (Strix Halo) auto-tuning does NOT touch us**: `src/core/arch_defaults.cpp`
  returns its 18 switches only for gfx1151, so `STRATA_EXPERT_V2` / `STRATA_QFUSE`
  (the new S26 kernels) stay off on our gfx1201.
- **Conversation caches from 0.1.39 are rebuilt on first use** (the cache version
  key changed): the first request after the switch re-reads its prompt. Expect one
  slow turn, not a regression.
- **Behaviour changes that matter for agent traffic**: empty assistant turns are no
  longer rendered into the next prompt (#886, `STRATA_KEEP_EMPTY_TURNS=1` restores);
  OpenAI `stop` / Anthropic `stop_sequences` are honoured on every path (#454);
  `tool_choice none/required` fixed (#790).
- **0.1.40.1 is a serve-layer hotfix** (engine identical to 0.1.40): a quoted
  `<tool_call>` in thinking or in a code fence stays text (#804, #1058), and —
  relevant to our NaN guard, which kills the engine mid-session — requests waiting
  during an engine restart no longer hang or die with `list.remove(x): x not in
  list` (#1012); a waiting request now continues on the new engine or ends at once
  with a 503 so the client can retry.
- **Upstream rewrote the repo history on 2026-10-06**: our old pin `6f32ec0` has
  no common ancestor with `main` (GitHub's compare API 404s), and `v0.1.39` is
  `a1641e9f`, not `6f32ec0`. Diff two archives, not `git log`. A git checkout of
  Strata needs `git fetch origin && git reset --hard origin/main` once.
- **Unchanged for us**: `data/expert-profile.bin` and `data/draft_vocab.bin` are
  byte-identical (md5 `ff1bc654…` / `4135aad3…`), the pack index format is still
  v3 / 19 fields (no re-pack needed), every engine arg in `strata.nix` is still
  parsed (`--spec-min-p` at `generate.cpp:1697`, absent from `--help` in both
  versions), and `serve/server.py`'s two error-body strings our `installPhase`
  rewrite targets are still verbatim (now at lines 4242 and 4250).
- `setup.py`'s tested ROCm is `7.10.0a20251120` (`setup.py:1493`); our build uses
  nixpkgs ROCm **7.2.3** and still compiles clean for gfx1201.

## 0.1.40.2 (2026-10-07)

Pinned `e8ca9afd` (v0.1.40.2), built
`/nix/store/v63bhabzfxwg6i8hkx8q93rb9r0q0jf9-strata-0.1.40.2`. This is the first
release after the history rewrite, so the pin moves forward normally. What matters
to us, read off the tree:

- **The guard diff needed 3 anchors moved** (2 in `verify.cpp`: the window-inputs
  comment is now two lines, and a new `if (inputs_pending)` join block sits before
  `stamp(l, 1, grp)`; 1 in `sampler.cu`: the `coupled_check("coupled_draft merge")`
  anchor is no longer at EOF because `sample_tokens_spec` follows it, so the
  additions moved to the closing namespace). The added lines are byte-identical to
  the 0.1.40.1 diff and it applies with `--fuzz=0`. See `strata-package.nix`.
- **All `postPatch` clamp targets and both `installPhase` serve strings are still
  present** (shifted): the S26 swiglu block is now `iq_kernels.cu:2326-2330`, the
  int8-KV scales are `kv_q8.cu:55` and `prefill/kernels.cu:1340`, and the two
  `serve/server.py` error bodies are at `:4741` and `:4749`. No clamp dropped or
  added; the built binary carries `verify: non-finite logits` and the
  `native_stage_audit_*` / `record_first_nonfinite` symbols.
- **The llama.cpp ggml pin is unchanged** (`3cf03257…`, `setup.py:165`), and the
  HIP build's cmake args (`setup.py:2412`) are exactly the ones
  `strata-package.nix` passes (`STRATA_ENABLE_HIP=ON`, `STRATA_ENABLE_CUDA=OFF`,
  `STRATA_BUILD_TESTS=OFF`, `STRATA_PREFILL_MMQ=ON`, `gfx1201`).
- **Default answers are byte-identical to 0.1.40** (upstream checked Q2_0,
  IQ3_XXS, Coder, IQ3_S). The new default-on speed-ups are bit-identical: the F4
  verify-window interleaved read (`STRATA_MMVQ_IL=0` turns it off, +1–4% decode)
  and, on Linux, the prompt stager sleeping instead of spinning plus the file tier
  reading through the page cache (#1194). `STRATA_PREFILL_CPU_SHARE` is opt-in and
  off, and Intel Arc is a separate SYCL port — neither touches this R9700 build.
- **#879 is still open** (updated 2026-10-07): the routed-expert data-path
  degeneration is not fixed in 0.1.40.2, so the local guard stays.
- **Live switch, 2026-10-07 15:36 BST**
  (`/nix/store/v63bhabzfxwg6i8hkx8q93rb9r0q0jf9-strata-0.1.40.2/bin/strata`,
  engine pid 903083): experts loaded 46.84 GiB at 3.21 GiB/s (22 s), GPU expert
  cache 13,104 experts / 24.87 GiB, `ready` in 26 s, `/v1/models` 200, and a
  57-token prompt decoded at 47.9 tok/s with 6/6 drafts accepted. No
  `verify: non-finite logits` fire on the first requests.

## UD-IQ4_XS (live since 2026-10-09 19:23)

Unsloth's ~4-bit **UD-IQ4_XS** is the one rung above IQ3_S this box can run, and
`ai.strataModel = "ud-iq4-xs"` has served it since **2026-10-09 19:23:07**
(`ExecStart` → `--config /nix/store/n53b8vynrljmpbv3ajfcq3sx1rmdmd3l-strata-ud-iq4-xs.json`,
model id `qwen3.8-flash-next-ud-iq4-xs`). It is **slower than IQ3_S** — see
"Measured" below — so `"iq3s"` is the fallback if decode speed matters more than
the weights.

**Files**: `scripts/fetch-strata-udiq4xs.sh` (three shards at the revision
`setup.py` pins, sizes + SHA-256 from `UNSLOTH_IQ4_XS_SHARDS`),
`scripts/repack-strata-udiq4xs.sh` (`iq_pack.py --gguf <shard1> --compat-bf16`,
no `--experts-bin`), and the switch itself: `ai.strataModel` in
`hosts/zen3-nixos/ai/default.nix` with the per-model paths/args in
`hosts/zen3-nixos/ai/strata.nix` (`models.iq3s` / `models.ud-iq4-xs`). The unit's
`ConditionPathExists = <pack>/index.txt` means a half-prepared pack never starts.

**What the file actually is** (read from the GGUF metadata, not the docs — and
note the GGUF tensor-type enum is `F32=0, F16=1, Q4_0=2, Q4_1=3, Q5_0=6, Q5_1=7,
Q8_0=8, Q8_1=9, Q2_K=10, Q3_K=11, Q4_K=12, Q5_K=13, Q6_K=14, IQ2_XXS=16,
IQ2_XS=17, IQ3_XXS=18, IQ1_S=19, IQ4_NL=20, IQ3_S=21, IQ2_S=22, IQ4_XS=23,
IQ1_M=29, BF16=30` — the same numbering strata's `name_of()` uses, *not* ggml's C
enum). Each shard is its own GGUF container: shard 1 is metadata only (0 tensors,
10.9 MB), shard 2 has 373 tensors incl. the PLE table, shard 3 the rest
(`split.count=3`, 1224 tensors in total). Per layer, all 48:

| tensor | quant |
| --- | --- |
| `ffn_gate_exps` / `ffn_up_exps` | IQ3_S in 47 layers, **IQ4_XS in blk.2** |
| `ffn_down_exps` | IQ4_NL in 43 layers, **Q8_0 in blk.2, 4, 30, 46, 47** |
| `ffn_*_shexp` (shared expert) + the 195 `hc_*` projections | Q8_0 |
| `token_embd` / `output` | Q8_0 / Q6_K |
| `per_layer_token_embd` (PLE) | IQ4_NL, 28.8 GB — the same table as GSQ's shard 2 |

Bytes by type across all three shards: IQ4_NL 49.09 GB (28.8 of it the PLE
table), IQ3_S 33.88, Q8_0 8.93, IQ4_XS 0.94, Q6_K 0.52 — **93.72 GB total**,
matching `setup.py`'s `download_gb: 93.7`.

**Why the pack needs `--compat-bf16`**: those Q8_0 `hc_*` projections are not a
form the AMD build can read yet (the native Q8_0 read path is "measured on AMD
only and not in this release", i.e. not in 0.1.41), so `iq_pack.py` rounds them
to BF16. Upstream measures that rounding as PPL 6-9 % *above* llama.cpp's on the
same file — so part of any UD-IQ4_XS quality gain can be eaten by the pack, and
that is the first thing to check if it ever goes live.

**The budget** (`--resident-budget-gib 55`, `setup.py:1515-1521` for this box:
RAM 94 GiB − `UNSLOTH_RAM_LEFT_GB` 24 − ceil(KV streamed to RAM ≈ 3), capped at
`int(arena_gb 59.5 / 1.0737)` = 55): every expert in RAM, no SSD expert tier.
That is **+8.6 GiB** over the IQ3_S engine's 46.84 GiB of resident experts
(~24 GiB of `available` left). Without the flag the engine sizes its own arena
for all 55.4 GiB and the box OOMs.

**What it costs** (predicted): the 24.87 GiB GPU expert cache holds ~11,000 of its
experts instead of 13,104 (avg blob 2.421 MB vs 2.046 MB), so 44.9 % of the 24,576
slots instead of 53.1 %. Estimated from the live hit rates (91.0 % at 113 K depth,
97 % short) and upstream's cold arm at 255 K: **~33-37 tok/s at 255 K** (vs 41),
55-70 short-context, prefill −5-10 %. `--max-context 262144` itself is
unaffected — the int8 KV is 13,728 B/token (13 cells × 1056 B) and
quant-independent, so `--kv-resident 32768` still costs 0.42 GiB of VRAM.

**Measured after the switch** (2026-10-09 19:23-19:30, real agent traffic at
66-70 K-token prompts): expert cache **10,679 experts / 24.08 GiB** — the
prediction was ~11,000, so the slot math was right. `ready` in 22 s, VRAM
32,370/32,624 MB, `MemoryCurrent` 39 GiB with **`MemorySwapPeak` 0** (the IQ3_S
unit had peaked at 5.3 GiB of swap), and no `FITS`/`DOES NOT FIT` line is printed
by `strata-server` at all — the "filling the GPU's expert cache (N experts, X GiB
of VRAM)" line is the plan you have to read. Decode **48-57 tok/s (52-56 once the cache is warm) at 90-93 %
hits (+4.4-7.0 % of routed experts over PCIe)**, against 62-68 tok/s at 92-97 %
for IQ3_S at the same depth: **~20 % slower**, worse than the 55-70 short-context
estimate. The hit rate is nearly unchanged, so the loss is per-miss cost — 1.7×
as many misses (3.8 % vs 2.2 % of routed activations) and each one 18 % bigger —
plus IQ4_NL/IQ3_S dequant. Prefill is fine: 62,546 tokens in 50 s = **~1,250
tok/s**, at or above IQ3_S. A short cold request is the worst case (60 tokens at
41.6 tok/s, 86.2 % hit). No `verify: non-finite logits`, no degenerate reply, and
the first sanity generation was coherent.

**The pack** (`scripts/repack-strata-udiq4xs.sh`, 2026-10-09 19:03, 1.4 GB in
`/home/cjdell/Strata/pack/ud-iq4-xs`): `index.txt` 1079 tensors / 303 served
natively / 0 in extra.bin / arena 1.38 GiB; `conversions.json` **460 tensors
converted to the engine's form (264 exact, 196 rounded, max |err| 0.0144)** —
against IQ3_S's `tensors: []`, this pack really does lose information to the
BF16 rounding; `compat-bf16.json` 195 tensors, 1.20 GiB, expert and PLE bytes
unchanged; `native_experts.txt` **v4** because blk.14's gate/up/down straddle the
shard 2/3 boundary (per-role shard column); tokenizer vocab 248320, merges
247587, pre qwen35.

**Tooling gotcha** (why both repack scripts now build their own python): 0.1.41's
`iq_pack.py` does `from gguf import ...`, whose package `__init__` imports
`gguf/metadata.py` → `yaml`, and `strata_tokenizer.py` imports `regex`. The
engine's `serverPython` has numpy + psutil only, so `python3.withPackages
[ numpy pyyaml regex ]` from the flake's nixpkgs pin is used instead — the iq3s
script had the same latent break and is fixed the same way.

**Switching back** is one line (`ai.strataModel = "iq3s"`) + `nixos-rebuild
switch`; both packs stay on disk, and the unit's `ConditionPathExists` still
protects a pack that is not built.

## 0.2.7.1 (2026-10-29)

Pinned `46c152a1` — the v0.2.7.1 tag (2026-10-28) points **exactly at main's HEAD**, so this is
bleeding edge with nothing newer above it. Follows 0.2.2..0.2.7 (2026-10-21..27); the app/Terminal/Control
layer is 0.2.7.1 and the engine source is `project(strata VERSION 0.1.53)`, `CMakeLists.txt:11`
(was 0.1.46.1 at `CMakeLists.txt:7`). Built
`/nix/store/yxly8rqbd9cpcd29894mz2baqsafbdhb-strata-0.2.7.1`, **live since 2026-10-29 03:11** —
`/v1/status` reports `"engine": "0.1.53"`.

**Audit patch re-base: 6 of 19 hunks rejected, all pure context shifts**, hand-placed and
regenerated from the patched tree (19 hunks, 280 additions, 0 deletions, added lines byte-identical
to the 0.2.1.1 file, `patch -p1 --fuzz=0` with **no offsets** and `git apply --check` clean):
verify.hpp gained `topk_scratch_` between `sel_` and `logits_`; the shared-expert site grew a
`note_prio_tail` body inside `if (sh_fork)`; the `hit_out` `grouped` call gained a trailing `true`
and an `ar_on()` sibling branch — `ar_on()` is `all_resident_ && !ar_off_` (verify.hpp:528), so at our
43 % expert cache it is **never live** and the audit does not need mirroring there; the new
`tap_on_`/STRATA_TAP_FILE block sits after `stamp(l, 24`; `tap_write` + STRATA_LOGITS_DUMP now sit
between the run()-tail `note_nonfinite` (the audit dump goes right after it — the second
`note_nonfinite`, in `Verifier::pl_finish`, is not the site) and STRATA_DBG_NAN; and in
`iq_kernels.cu` upstream inserted the `if (g_exp_phase == 3) return;` bench early-return after
`check("native_expert_grouped/gu")` — the gate/up `stage_audit` pair is placed **before** it. The
other 13 hunks landed with offsets up to +1506. Guard anchors intact (server.py's 17
non-finite/retry lines, `logits_nonfinite_rows` at verify.cpp:2498, `note_nonfinite`/`hits_in_combine`).

**Both int8-KV clamps still needed and unique**: `kv_q8.cu:55` unchanged; the prefill target moved to
`kernels.cu:2257` (was 2199; `hf_sat` still :64). Both `installPhase` server.py rewrites present once
(now :7664/:7676). `import serve.server` verified against the built output; the five `strata_control`
modules it needs are still stdlib-only (rich/textual stay in `strata_cli/dashboard|monitor`,
certifi/truststore in `strata_control/tls.py` function bodies), so `serverPython` is unchanged. The
ggml pin is unchanged (`setup.py:222`, still `3cf03257`), all 18 engine args still parse, CMake options
unchanged, `STRATA_VISION_HIP` is a separate opt-in program (we keep the CPU encoder).

**Behaviour changes to expect** (from the release notes; the ones that touch this box): 0.2.7's
"Faster Qwen on Radeon RX 9000 / AI PRO R9700" is **default-on** — the per-token lookup table stays in
RAM and the decode card/CPU split starts differently, and **answers can differ in wording**. 0.2.6/0.2.7
re-froze `STRATA_DEFAULTS=026` for Qwen. 0.2.5 uncapped the RAM expert store (48 GB → hold every routed
expert where free RAM allows) — watch RAM during the load given the `-cram` OOM history. First live
numbers (short turns, warm load): **decode 60-64 tok/s at 92-94 % expert-cache hits** (was 48-57 at
90-93 % on 0.2.1.1), a 138K-prompt read streamed clean, no audit fires, `HSA_USERPTR_FOR_PAGED_MEM=0`
and the ROCm 10 runtime mapping confirmed unchanged.

## 0.2.1.1 (2026-10-20)

Pinned `9ae93f7b` (v0.2.1.1, the Windows-Terminal hotfix on 0.2.1 of the same day; 0.2.1 follows
0.2.0-beta `3d1fb480` of 2026-10-19 and 0.1.45 `477ac13c` of 2026-10-17), built
`/nix/store/k91dljvza0ksdr3m262nbqcbmglr0kw7-strata-0.2.1.1` (HIP/gfx1201; `strata-server
--help` imports the whole serve layer, and the engine binary opens with `opened 2 GPU queues
in a fixed order` — the new queue priming is live in the binary). **0.2.0 re-cut the repo into app + Terminal + engine** — the
"engine package 0.1.46" of the release notes is the source in this tag (`project(strata VERSION
0.1.46.1)`, `CMakeLists.txt:7`); the new `apps/`, `bin/`, `docker/`, `integrations/`,
`packaging/` trees and `strata.py` are the app and the Terminal and are not built here.

**One real breakage, fixed:** `serve/server.py` now imports the Terminal's Python packages at
module scope — `from strata_control import engine_component, hipblaslt_tuning, vision_reader,
draft_layer, user_args` (server.py:68-72) — and `strata_control` reaches `strata_cli`. Both are
stdlib-only on that path (`strata_tokenizer` is `tools/strata_tokenizer.py`, reachable via
server.py's own `sys.path.insert`), so `installPhase` now copies `strata_control/` and
`strata_cli/` next to `serve/tools/data`; without them `python -m serve.server` dies with
`ModuleNotFoundError`. Verified before building: `import serve.server` succeeds against exactly
those five dirs plus the unchanged `serverPython`. No new *required* third-party import —
jsonschema/referencing stay lazy+optional in `serve/structured.py` (absent → "one JSON object"
checking only, same as today) and textual/requests/tqdm are Terminal/monitor-only.

**The audit patch needed a real re-base** (the first since 0.1.40.3 that did not land by
offset alone): 5 of 19 hunks were rejected by upstream context changes and were re-placed by
hand — `verify.cpp`'s audit-alloc insert (a hand-off-counter block was added right after the
arena `cudaMemset`), the per-window `lay_flags_` reset (a `keep_rows` line now follows `hrow0`),
`audit_hit_rows` (a new `m_bal_` branch moved into the trailing context of the `hit_out`
`grouped` call), and in `iq_kernels.cu` the definitions block (new `native_expert_set_expdec*`
setters between `native_grouped_set_v1` and `native_expert_grouped`) and the stage-2 audit (the
`sw_v1` branch grew `|| L.had_block > 0` and a `hadamard_rows` call). The other 14 landed with
offsets up to +1159 — `iq_kernels.cu` gained ~1,100 lines (the S26/S27 v2/v2k expert paths; v2
is `STRATA_EXPERT_V2=1` opt-in, v2k is default-on for Q4_K/Q5_K gate/up — neither matches our
IQ4_XS geometry, so our model still runs the audited kernels). Regenerated from the patched
tree: 19 hunks, 280 additions, 0 deletions, `patch -p1 --fuzz=0` and `git apply --check` both
clean with **no offsets**, added lines byte-identical to the 0.1.44.1 file. `sampler.cu` is
byte-identical to 0.1.44.1; the guard it rides on is untouched (the 1,560 changed lines of
`server.py` touch no non-finite line).

**Both int8-KV clamps still needed, still unique:** `kv_q8.cu:55` (that file only *added* a
`STRATA_EXPERIMENTAL_SM60`-gated 8-wide gather below the shipped kernels) and
`prefill/kernels.cu:2199` (was 1702; `hf_sat` now at :64). Both `installPhase` rewrites of
`serve/server.py` matched (now 6743 and 6755). The ggml pin is unchanged
(`setup.py:213 LLAMA_CPP_COMMIT = 3cf03257…`). Build surface unchanged: `add_executable(strata
src/program/generate.cpp)` at `CMakeLists.txt:735`, every cmake flag we pass is still an option,
`tools/vision` still builds `strata-vision` with `LLAMA_DIR`/`STRATA_VISION_CUDA`/
`STRATA_PORTABLE` — it gained `STRATA_VISION_HIP` (the AMD GPU picture reader: 57 ms vs 3.13 s
per picture, ~1.4 GiB VRAM; we keep the CPU encoder, the expert cache has 232 MiB free), and
all 19 engine args in `strata.nix` are still parsed.

**Behaviour changes to expect** (no config change; the A/B switches are in the `strata.nix`
comments):

| change | since | effect here | revert |
| --- | --- | --- | --- |
| Flash-Next answers | 0.1.45 | **byte-identical** to 0.1.44.1 on every machine upstream tested (HIP gfx1201 included) | — |
| long-prompt top-k + exact scorer (#1749/#1943) | 0.1.45 | R9700 prompt reads: 131K +8.7 %, 230K +16 %, 500K +79 %, answers identical | — |
| `STRATA_HIP_QUEUE_PRIME` | 0.2.0/2.1 | the two busiest GPU queues open in a fixed order at start: before, ~half of fresh MTP engines read prompts 8–14 % slower depending on which compute pipe the firmware gave them (10/32 slow starts before, 0/32 after); answers identical | `=0` |
| `STRATA_FILE_TIER_PROBE` | 0.2.1 | start-up probe (96 × 1 MiB both ways, <2 s) picks file cache vs unbuffered for models read in place; cannot change answers | `=0` |

Not applicable: the compute-only-card reserve drop (the probe cannot tell on AMD Linux, the
safety default stays), hipBLASLt tuning tables (opt-in for R9700, and not bit-identical —
first-token KL 0.016), Flash-Next `--parallel N` (0.1.45 added it; we stay at one slot,
`docs/strata-batching.md`), `STRATA_IGPU_PROMPT_SET` (780M/760M), hybrid-CPU core counting, and
the whole app/Terminal/Docker/`strata bench run` layer. The 0.1.43/0.1.44 RDNA4 defaults table
above stays in force unchanged (HC_Q8, route-tail-skip, measured PCIe, 16384 chunk).

**#879: closed, but not dead — and the fresh repro is our quant.** The maintainer closed it
2026-10-13 as a stale-tracker sweep ("comment and we will reopen"); on 2026-10-19 a new
reproduction landed (issue still closed): engine 0.1.45, RTX 3080, an 18,442-token agent prompt
with 48 tool schemas → `non-finite logits (#879)` at the last window **every time**;
`STRATA_PREFILL_MMQ=0` answers the same body; `STRATA_DBG_NAN` puts the birth in **layer 1's MoE
gate/up on the MMQ prompt path, types 22/42 — IQ4_XS gate/up, our pack's family** (our build
passes `-DSTRATA_PREFILL_MMQ=ON`). The audit stays the point of our patch; the ROCm 10.0.0
runtime swap remains the thing that stopped our fires.

## 0.1.44 / 0.1.44.1 (2026-10-14)

Pinned `296b59d2` (v0.1.44.1, the hotfix on 0.1.44 `ed4773eb` of 2026-10-13, which follows
0.1.43.1 `a0116b27` of 2026-10-12), built
`/nix/store/yrxmsd6ss59ni7874xcri0mn9rf2kr8b-strata-0.1.44.1` (HIP/gfx1201). **Nothing of ours
had to be rewritten:** the audit patch applied in `patchPhase` with **no offsets and no fuzz**
(19 hunks, 280 additions, 0 deletions — the added lines are *byte-identical* to the 0.1.43
file, only the hunk line numbers moved: +11 `verify.hpp`, +4 `iq_kernels.hpp`, +22/+35/+134
`verify.cpp`, +190/+206 `iq_kernels.cu`), both `--replace-fail` int8-KV clamps matched (each
target still unique: `kv_q8.cu:55` — that file is byte-identical to 0.1.43 — and
`prefill/kernels.cu:1702`, up from 1691), and both `installPhase` rewrites of `serve/server.py`
matched (now 5861 and 5869). The ggml pin is unchanged (`setup.py:167 LLAMA_CPP_COMMIT =
3cf03257…`), so the `llama` fetch did not move. Build surface unchanged: still no `install()`
rules, `add_executable(strata src/program/generate.cpp)` at `CMakeLists.txt:622`, no new
third-party import in `serve/` (still jinja2 / PIL / psutil), and all 13 engine args in
`strata.nix` are still parsed. Upstream added its own `flake.nix` (#2198); we keep ours.

**The three answer-changing RDNA4 defaults now in force** (each documented in a comment in
`strata.nix`, none set there — we take upstream's defaults):

| switch | since | effect here | revert |
| --- | --- | --- | --- |
| `STRATA_ROUTE_TAIL_SKIP=7` | 0.1.43 | ON (we hold ~43 % of experts in the GPU cache, the skip only stays off from 90 %); KL ~0.003–0.006 | `=0` |
| measured PCIe share | 0.1.43 | replaces the fixed fraction | `STRATA_PCIE_FRAC_DEFAULT=old` |
| `STRATA_HC_Q8` | **0.1.44** | hc\_* projections read as Q8_0, not BF16: R9700 decode +2.5–4 %, mean KL 0.0003–0.0010, answers can differ in near-ties. For our `--compat-bf16` pack the engine requantizes the pack's BF16 copy to Q8_0 at load (`fused_gr.cu:2090 gr_quantize_q8_0_kernel`, new in 0.1.44) — a little load time and `hc_q8_bytes` of extra arena (`native_dense.cpp:496`) | `=0` |
| `STRATA_GFX12_CHUNK` | 0.1.43/44 | a bare `--prefill auto` (what we pass) may chunk prompts at 16384, not 8192; 0.1.44's #2090 guard (`generate.cpp:6634`) keeps 8192 when free RAM does not cover the extra slot loan + 6 GiB — relevant with `--resident-budget-gib 55` on 94 GB | `=0` |

`STRATA_GFX12_DEFAULTS=0` turns off the last two at once. `STRATA_PF_FUSED`'s new gfx12 default
covers IQ3_S/IQ3_XXS gate/up only, so UD-IQ4_XS keeps MMQ — no answer change from it. Two more
new defaults are bit-identical per upstream: `STRATA_COMMIT_BATCH` (one commit-graph launch per
layer kind, `verify.cpp:2041`) and `STRATA_MTP_HIP_PRIO` (draft stream at high priority on
gfx1200/gfx1201, `mtp.cpp:445`).

**Two 0.1.43.1 fixes land with this update** (our previous pin was 0.1.43, so we did not have
them) and they map onto our two remaining failure classes: the prompt path's pageable
host→GPU copies now go through a ring of **pinned** buffers
(#1996, an RX 7900 XTX memory-access fault after ~30 min; a 65-min 6-client R9700 stress ran
clean) — the same class we expose with `--kv-resident` streaming KV into host RAM; and the PLE
n-gram table is **no longer switched to mmap by itself** (the start-up check only warns now,
`STRATA_PLE_AUTO_MMAP=1` restores the 0.1.42 behaviour) with the watchdog's slow-disk allowance
widened — our 26.82 GiB PLE table is read with direct IO, and the auto-mmap made SATA prompts
~7× slower (#2040). Also fixed: a short prompt right after start ending the engine with
`lending the prompt path its slots failed` (#2090). From 0.1.44: `serve/server.py:528
START_RETRIES` (default 3) retries a server start that dies inside the GPU runtime's own
set-up — "a ROCm `hsa_exception` one start in twenty after a quick restart" — at 2, 4 and 8 s.

**Checked and dismissed**: 0.1.44's new fp16 scale stores are `gr_quantize_q8_0_kernel`
(`fused_gr.cu:2099`, **weights**, bounded) and the NVFP4 dequant scales (`iq_kernels.cu:2071/
2088`, `prefill/kernels.cu` `row_sd`) — NVFP4 is NVIDIA-only, never loaded here. The one new
q8_1 *activation* emit site upstream added (the `STRATA_HC_Q8` read) already goes through
`q8_1_finite`/`q8_1_quant`/`q8_1_ds`. `native_mmvq.cu:2074` (was 1985) still writes a fixed
synthetic scale. `s2_expert_grouped.cu:193` does keep an unclamped Q8_0 activation scale, but
it predates this pin and 0.1.44 only added a geometry `static_assert` to that file.
`serve/server.py` gained four more `the next request restarts it` exits (5559, 5933, 5966, 6085
— the 503, Responses and Anthropic paths) that our `"server error"` rewrite does **not** match;
Pi talks to `/chat/completions`, so coverage is still complete — revisit if we move routes.

**#879 is still open.** Neither 0.1.44 nor 0.1.44.1 touches the routed-expert data path (0.1.44's
300 changed lines in `iq_kernels.cu` are the route-resident work and NVFP4 dequant), so the
audit stays the point of our patch. Note the ROCm 10.0.0 runtime swap (2026-10-13,
`lib_dirs = ["${rocm10}/lib"]`, built by `ai/rocm10-runtime.nix` since 2026-10-14) is still the
thing that actually stopped the fires — 0 in 1911 requests — and it is orthogonal to the version
pin.

## 0.1.43 (2026-10-12)

Pinned `7695859a` (v0.1.43), built `/nix/store/1s8ca3glsa0arp6hk39xnqv6sc7rkcgp-strata-0.1.43` (HIP/gfx1201; the patch applied in
`patchPhase` with **no offsets and no fuzz**, and every `--replace-fail` clamp and both
`installPhase` rewrites still matched, so both int8-KV clamps and the Pi-retry rewrite are
intact). The ggml pin is unchanged (`setup.py:166 LLAMA_CPP_COMMIT = 3cf03257…`), so the
`llama` fetch in `strata-package.nix` did not move.

**Upstream shipped our guard.** #1892 (lask3802) is a finiteness guard on by default behind
the *same* `STRATA_NAN_GUARD` switch our patch invented, and it *recovers* instead of
erroring: `logits_nonfinite_rows(head_logits_, T, n_vocab, m_nf_)` is recorded in every
window graph (`verify.cpp:1795`), `Verifier::note_nonfinite` fills
`nf_row_/nf_pos_/nf_mask_`, `generate.cpp` ends the request `DONE … nonfinite` emitting
**none** of the poisoned window's tokens and drops every cached state (the next request
re-reads the prompt from token 0), and `serve/server.py` raises `EngineNonFinite` and
retries the request once (`nf_retried`). Engine log line `non-finite logits (#879)`; costs
≤0.2 % decode; `STRATA_NAN_GUARD=0` turns it off. **Our guard is therefore gone from the
patch** — two guards behind one env var, ours being the one that only failed the window and
relied on the `"server error"` rewrite to get Pi to retry the whole request, was not a trade
worth keeping.

**What is left is the audit** — and that is the half upstream still wants. #879 is open
(updated 2026-10-11): the maintainer ran MKheru's stress script over 1,870 R9700 requests in
four configurations plus 276 MMQ kernel cases and *could not* fire it, and asks the reporters
(we are one of them — `cjdell`, 2026-10-05, the second HIP/RDNA4 data point) for (1) whether
it still fires without MKheru's CUDA-helper patch, (2) `STRATA_PREFILL_CPU_SHARE=0`,
`--pcie-frac 0` and the stock power limit, (3) the `expert cache N slots` line and
`STRATA_DBG_NAN` from **more than one** fire. Our dump prints per-stage
(layer, row, col, raw bits) for *every* fire, which is more than `STRATA_DBG_NAN` (first
fire only) reports. The file is renamed **`strata-kernel-audit.diff`** to say what it is:
19 hunks, 280 additions, 0 deletions.

Still open from MKheru's 2026-10-10 analysis (**not** applied): every one of their 28 fires
was a prompt read of 198–258 new tokens over a cached conversation, and `--short-read 260`
— which routes those reads through the verify windows instead of the batched prompt path —
gave 0 fires in 770 requests at no measurable speed cost. Upstream could not reproduce the
fire at all, so that is a workaround for a defect they cannot see rather than a fix; with
#1892 recovering instead of answering `!`, we keep the speed and the capture.

Two cost fixes done while re-basing:

- `lay_flags_` (the per-stage flags) is allocated **only** with `STRATA_KERNEL_AUDIT=1`.
  Until now it was allocated unconditionally, so ~10 audit probes per layer sat in every
  captured verify graph whether anyone was reading them or not — and 0.1.43 is precisely
  the release that priced that: it ships `STRATA_DUMMY_NODES` to measure "one empty kernel
  node per layer" and wins 1.6–2.0 % decode by removing and fusing decode-window nodes.
  Every write site is gated on the pointer, so with the audit off the window graph matches
  upstream's. `strata.nix` still sets it to `1` — we are mid-hunt; set it to `0` for full
  speed once we have a capture.
- The failure dump moved to just after `note_nonfinite(T, nullptr)` and rides on upstream's
  `nf_mask_` instead of its own scan, prints every fire, and **no longer fails the window**.
  It needs `STRATA_NAN_GUARD` unset (those are the flags it reads) and
  `STRATA_KERNEL_AUDIT=1` for the per-layer lines.

Three sites needed a re-base; the other 16 hunks moved by offset alone:

- the layer-input probe: 0.1.43 inserted the `STRATA_DUMMY_NODES` block between
  `q8_attn = gr_read_group(…)` and `if (inputs_pending)`;
- the attention-output probe: a new `stamp(l, 32, grp)` profile line after
  `q8_ffn = gr_read_group(…)`;
- the routed-total probe: 0.1.43's fused combine made the hit add **conditional**
  (`hits_in_combine`, `fuse_hits_on`, the decode default) —
  `native_moe_combine_multi_hits_added` folds it inside the combine, so `parts_out` is not
  the routed total there and sampling it would have lied. That probe is now gated
  `&& !hits_in_combine`; the `hit_out` and miss-row probes moved *before* the add
  (`moe_hit_add` only reads `hit_out`, so they see the same bytes), and site 4 (the layer's
  whole contribution, after the combine) still covers the fused case.

Behaviour to expect on this box (no config change made, but they move answers):

- **`STRATA_ROUTE_TAIL_SKIP=7` is now the default on HIP gfx1200/gfx1201**
  (`generate.cpp:8203`) — it was CUDA-only in 0.1.42. It stays off only from 90 % of the
  experts in the GPU cache on a single card (60 % on an AMD layer split, #1884), and we sit
  at 10,679 of 24,576 = **43 %**, so it is ON: KL ~0.003–0.006, answers differ slightly from
  0.1.42. `STRATA_ROUTE_TAIL_SKIP=0` restores 0.1.41's bytes.
- **The measured PCIe share is now the default here too** (`STRATA_PCIE_FRAC_DEFAULT=old`
  reverts). Both of these are among the variables the maintainer asks us to pin when
  reproducing #879: `STRATA_ROUTE_TAIL_SKIP=0 --pcie-frac 0` is the A/B.
- **`STRATA_PF_FUSED`'s new gfx12 default does not touch us**: it is IQ3_S/IQ3_XXS gate/up
  only (`moe_fused_iq.cu:1131` `if (env < 0 && gu_type != T_IQ3_S && gu_type != T_IQ3_XXS)
  return false;`), so UD-IQ4_XS keeps MMQ — no answer change from it.
- Long prompts may chunk at 16384 (`STRATA_GFX12_CHUNK=0` keeps 8192).
- `STRATA_DROP_CACHE_ON_EXIT` is new, opt-in, off — **keep it off**: it
  `posix_fadvise(DONTNEED)`s the model files when the server stops, and that warm page cache
  is what makes a restart take seconds instead of minutes.
- Upstream's R9700 rows vs 0.1.42: decode +2–10 % (IQ3_S +6–14 %), prompt +12–14 %
  (32K +17 %, 64K +27 %); with a 16 GB card's cache +21–38 %. `bench.sh` /
  `tools/strata_bench.py` is new if we ever want to publish numbers.

Still byte-identical, still ours: `kv_q8.cu` and `src/prefill/kernels.cu` (0 changed lines
again) — `kv_q8.cu:55` and `kv_append_kernel` (`prefill/kernels.cu:1691`) write `amax / 127`
to fp16 unclamped, so clamps (2) and (3) stay, and they are the reason `--kv int8` is safe.
Both `installPhase` rewrite targets moved to `serve/server.py:5392` and `:5400`, verbatim.

## 0.1.42 (2026-10-10)

Pinned `61b3fb5d` (v0.1.42), built
`/nix/store/m2nlr8xyhwvxm27b5n9g62qj3k9q033w-strata-0.1.42` (HIP/gfx1201; the
build succeeded with every `--replace-fail` clamp and `installPhase` rewrite still
matching, so our patch and both int8-KV clamps are intact). Not yet switched on the
live service — the box is still serving UD-IQ4_XS on 0.1.41 (see "Deploy" at the
bottom).

What changed for us (read off the two trees, not the changelog):

- **`gfx1201` gets a HIP-compiler workaround (#1474).** `iq_kernels.cu:1708`'s
  "half path's negative scale times +0 folds to +0" fix (previously gfx1151 only)
  now also covers RDNA4 gfx1200/gfx1201 (ROCm 7.10) — the card we run. Nothing to
  configure; the q8_1 sites #1448 clamped stay clamped.
- **The gfx12 prompt switches are on by default (#1478)**: `STRATA_GDN_HEAD`,
  `GDN_PP=2`, `GDN_CONVL2`, `GDN_NOY`, `CVEC_FUSE`. Residual and logits are
  byte-identical at 4K/20K, prompt +0.8%/+1.6%/+1.8% at 4K/16K/32K (upstream; the
  reporter saw +8%/+4% on another config). `STRATA_GFX12_DEFAULTS=0` turns them
  off. This is the one AMD-relevant speedup.
- **The two new answer-changing defaults are CUDA-only, so nothing for us.**
  `STRATA_ROUTE_TAIL_SKIP=7` (skip an un-resident expert the whole window ranks
  ≤7th) and the measured PCIe share are both off on AMD/Intel and layer splits;
  upstream's table scores the R9700 at +0.03%/+0.1% decode, +0.9%/+0.3% prompt
  versus 0.1.41, and includes it in the identity checks (one card, 2-card split,
  gfx12 switches on and off).
- **The two int8 KV clamps are still ours.** `kv_q8.cu` and
  `src/prefill/kernels.cu` are byte-identical to 0.1.41, so `kv_q8.cu:55` and
  `kv_append_kernel` (`src/prefill/kernels.cu:1691`) still write `amax / 127` to
  fp16 unclamped. Clamps (2) and (3) stay.
- **`strata-nan-guard.diff` needed exactly one re-base.** 0.1.42 inserted a new
  A770 XMX block (`kXmxGroupMax`, `iq_xmx_grouped`) in `iq_kernels.hpp` between
  `native_expert_scratch_bytes` and the `native_expert_grouped` doc comment,
  moving that hunk's trailing context; the other 18 hunks applied with pure
  offsets. The patch was regenerated from the patched 0.1.42 tree and now applies
  with `--fuzz=0` and **no offsets** (19 hunks), and the added lines are
  byte-identical to the previous diff (277 additions, 0 deletions — verified by
  diffing the `+` lines of the two patch files). `verify.cpp`'s 161 changed lines
  (per-GPU `STRATA_ROUTE_RESIDENT` counters #1578, `logit_bias` plumbing, the
  `always_publish_` fence) are unrelated; the hunks still land in
  `Verifier::init`/`run`/`record_window` and inside `native_expert_grouped`.
- **#879 is still open** (updated 2026-10-10), no 0.1.42 change references the
  routed-expert data path, so the guard stays needed.
- **Serve-layer fixes worth noting:** a reordered tool set keeps its first-seen
  order so the prompt cache survives (#1624); llama.cpp's `repeat_penalty` /
  `repeat_last_n` are accepted in configs and requests; `reasoning_loop_recovery`
  now catches a loop written as one long word (#1753). Both `installPhase`
  rewrite targets moved to lines 5269 and 5277, still verbatim.

Verified in the built package: the binary prints `strata 0.1.42`, carries
`verify: non-finite logits` and the audit line (`strata verify:   kernel-stage
  audit: first non-finite in %s of layer %d, flat %lld, bits 0x%08x`), and the
installed `serve/server.py` has both `server error: ` prefixes at 5269/5277.

## 0.1.41 (2026-10-09)

Pinned `fb58e0d0` (v0.1.41), built
`/nix/store/ap1x4fnmjwvmirrjp3d02x58s9vgj122-strata-0.1.41` (HIP/gfx1201,
build phase 1 min 19 s). 105 files differ from 0.1.40.3. **Live since 2026-10-09
17:23:48** — `ExecStart` is `…-strata-0.1.41/bin/strata-server` and the engine child
(`pid 239959`) reads back to the same store path; experts loaded 46.84 GiB at
4.40 GiB/s (16 s), GPU expert cache 13,104 experts / 24.87 GiB, `ready` in 15 s, and
the first turns decoded at 66-68 tok/s with 92-97 % expert-cache hits (0.1.40.3 was
65 tok/s, so "equal" as upstream's table claims). No `verify: non-finite logits` and
no `no progress for` line since the switch.

What changed for us (read off the two trees, not the changelog):

- **#1448 takes over one of our clamps.** "q8_1 scale overflow at the three
  remaining emit sites is clamped like the others": upstream now clamps the S26
  fused swiglu+q8_1 store (`iq_kernels.cu:2323-2330`), `verify_kernels.cu`
  `gdn_q8_1_store` and `fused_gr.cu gr_q8_tail` with
  `q8_1_finite/q8_1_quant/q8_1_ds` — byte-for-byte what our `postPatch` clamp (1)
  wrote, and the same fix for the two `STRATA_QFUSE` sites we had deliberately
  left alone. **Clamp (1) is therefore deleted from `strata-package.nix`**: its
  `--replace-fail` targets are gone from the file and it would break the build.
  The only `q8_1` `ds` store in 0.1.41 not going through `q8_1_ds` is
  `native_mmvq.cu:1985`, which writes a fixed synthetic scale
  (`0.001 + r*1e-9`), not an `amax`-derived one — no overflow risk.
- **The two int8 KV clamps are still ours.** #1448 did not touch them:
  `kv_q8.cu:55` (decode append) and `kv_append_kernel` in
  `src/prefill/kernels.cu:1691` (prompt append; it moved from 1340) still write
  `amax / 127` to fp16 unclamped. We run `--kv int8`, so clamps (2) and (3) stay.
- **`strata-nan-guard.diff` applies with `--fuzz=0` and offsets only** — verified
  against the fetched source: `verify.cpp` hunks +35/+43 lines, `iq_kernels.cu`
  +72/+80, and `sampler.cu` plus all three headers (`verify.hpp`,
  `iq_kernels.hpp`, `sampler.hpp`) byte-identical to 0.1.40.3. The hunks still
  land in `Verifier::run`/`record_window` and inside `native_expert_grouped`.
  `verify.cpp`'s only real change is the opt-in `STRATA_ROUTE_RESIDENT` plumbing
  (off by default, changes answers); the rest of `iq_kernels.cu` is the AMD
  expert-layout rework behind `STRATA_EXP_LAYOUTS`, which is **0 for a gfx1201 HIP
  build** (`#if defined(STRATA_HIP_GFX906) || !defined(__HIPCC__)`), so the expert
  path we run is unchanged and `exp_mode()` does not even exist here.
- **#879 is still open** (last update 2026-10-09, 6 comments) and no 0.1.41 change
  references it or the routed-expert data path, so the guard stays needed.
- **Hang/watchdog news** (relevant to `docs/strata-hang.md`, not a claimed fix):
  the #29 engine watchdog now tolerates up to `STRATA_WATCHDOG_IO_S` (default 10×
  the 60 s limit) of silence while the file tier is still being read (#1407), and
  `serve/server.py` now ends and restarts an engine silent for
  `STRATA_ENGINE_STALL_S` (90 s) that also uses no CPU, no disk and an idle GPU
  (#1317) — that one needs `psutil`, which `serverPython` in this derivation
  already bundles. Our hangs say "waiting for the GPU (attention, router)", so the
  IO allowance only removes a false-positive class.
- **Speed: nothing for this card.** Upstream's own table says "1x Radeon AI PRO
  R9700, Linux, Q2_0: equal" for prompt and decode. The two changed defaults are
  multi-GPU (`--batch-groups auto`) and NVIDIA-only (`STRATA_PREFILL_CPU_SHARE`,
  scoped in the notes to "one NVIDIA GPU without `--batch` slots; layer splits,
  batch and AMD are as before"), so there is nothing to pin back on a single
  gfx1201 card and no reason to set `STRATA_PREFILL_CPU_SHARE=0`. `serve/server.py`
  also raises the listen backlog to 256 (`STRATA_HTTP_BACKLOG`) and caps request
  bodies at 256 MiB (`STRATA_MAX_BODY_MIB`) — our 450 KB agent prompts are far
  under it.

Verified in the built package: the binary prints `engine=0.1.41`, carries
`verify: non-finite logits` and the audit lines (`strata verify: kernel-stage
audit: first non-finite in %s of layer %d…`, the HIT/MISS row dumps), and the
installed `serve/server.py` has both `server error: ` prefixes at 4991/4999 (the
same two `installPhase` targets, both still verbatim in the upstream file).

## 0.1.40.3 (2026-10-08)

Pinned `d5ea7133` (v0.1.40.3), built
`/nix/store/mcvch76h0ab3icsxxvrns58cz76qc21x-strata-0.1.40.3`. A small hotfix on
top of 0.1.40.2 — 28 files differ, and **none of them is a file we patch**:
`serve/server.py`, `src/core/verify.cpp`, `src/kernels/cuda/sampler.cu`,
`src/kernels/cuda/iq_kernels.cu`, `src/kernels/cuda/kv_q8.cu` and
`src/prefill/kernels.cu` are byte-identical between the two tags. So
`strata-nan-guard.diff` still applies with `--fuzz=0` unchanged (checked against
the 0.1.40.3 tree), every `postPatch` clamp target is still at the same line
(`iq_kernels.cu:2326-2330`, `kv_q8.cu:55`, `prefill/kernels.cu:1340`) and both
`installPhase` serve strings are still at `serve/server.py:4741` / `:4749`. The
ggml pin is unchanged (`setup.py:166 LLAMA_CPP_COMMIT = 3cf03257…`), so the
`llama` fetch in `strata-package.nix` stays as it is. Nothing was re-based, and
no clamp was dropped or added — upstream still writes `amax / 127` to fp16
unclamped at all three sites.

What changed that we care about:

- **#1357** (`src/core/mtp.cpp`): `native_router_top10` is now called only when
  `g.n_expert == 512 && K == 10`, else the generic `router_top10` (the native
  kernel reads 512 floats a row). Our pack IS 512-expert / top-10, so nothing
  changes here — but 0.1.40.2 would have run that kernel on any other pack's MTP
  draft layer.
- **#1385** (`tools/strata_tokenizer.py`): `_bpe` now caches `self.ranks.get` in a
  local, after CPython 3.14.4 was seen handing that frame an int for `self`
  (`'int' object has no attribute 'ranks'`). We run this Python layer on CPython
  3.14.7, so worth having.
- **#1392** (`serve/web/app.js`): a turn with no answer text (reasoning only, or a
  stop before the first content token) goes back in the history as an assistant
  turn with `reasoning_content`, so the web UI's history keeps alternating — the
  shape of the thinking-only turns the #879 incidents produced.
- Windows-only: #1376 (on a 16 GiB+ HIP card under WDDM an auto expert cache now
  keeps a 2560 MiB floor) and #461 (copy the HIP runtime's whole DLL closure next
  to the exe). On Linux `generate.cpp` now says "no GPU is visible and this user
  cannot open /dev/kfd" instead of blaming another program for the VRAM.
- **#879 is still open upstream** (last maintainer update 2026-10-07: could not
  reproduce, asking reporters to retry on 0.1.40), so the local finiteness guard
  stays, and so do the clamps.

Verified in the built package: the binary prints `engine=0.1.40.3`, carries
`verify: non-finite logits` and the audit symbols (`record_first_nonfinite`,
`native_stage_audit_alloc/layer/get`), and the installed `serve/server.py` has
both `server error: ` prefixes at 4741/4749.

**Build gotcha:** the first build of 0.1.40.3 died with a gcc ICE —
`free(): invalid next size (normal)` / `during IPA pass: icf` /
`src/core/expert_source.cpp:4016:1: internal compiler error: Aborted` — while
`/` was at 100 % full. A plain retry with space freed built clean, and gcc is
16.2.0 in both nixpkgs pins, so read that ICE as disk pressure / a flaky
cc1plus, not a reason to touch the toolchain.

**Not switched on the live service yet**: `strata` still runs
`/nix/store/v63bhabzfxwg6i8hkx8q93rb9r0q0jf9-strata-0.1.40.2/bin/strata`
(pid 903061 since 2026-10-07 15:35). Deploy = `sudo nixos-rebuild switch --flake .`
(zen3-nixos has autoRollback commented out — no `nixos-confirm`), then check
`systemctl show strata -p ExecStart` and
`readlink /proc/$(pgrep -f '[b]in/strata --serve')/exe`.

## nixpkgs 26.11.20261006 (2026-10-08)

`nix flake update nixpkgs`: `a7868a72…` → `151fa4e8…` (the nixos-unstable branch
head as of 2026-10-06 04:29 UTC, so this is current, not a lagging channel).
Nothing relevant moved for us: ROCm is still **7.2.3**, gcc **16.2.0**, cmake
**4.4.3**, python **3.14.7**. All 22 `nixosConfigurations` still evaluate, and the
zen3-nixos toplevel needed only 21 derivations built + 22 fetched (30 MiB —
curl/openssl/krb5/libssh2/nghttp2 refreshes plus our own strata and config
units), i.e. the bump is cheap on this host. Other hosts were evaluated but not
built.

## Why llama-swap is off

Both want the R9700's VRAM and tens of GB of RAM, and Strata exists to run a
model that does not fit. `hosts/zen3-nixos/ai/default.nix` imports
`./strata.nix` and leaves `./llama-swap.nix` commented out. Re-enable the
llama-swap import *and* drop the strata one together to go back; the two must
never be imported at once.

## What is where

| Piece | Path |
| --- | --- |
| GGUFs (4 quants, IQ3_S in use) | `/home/cjdell/Models/Qwen3.8-Flash-Next-GSQ-RCO-GGUF/` |
| pack (index + dense + tokenizer) | `/home/cjdell/Strata/pack/iq3s/` (~1.5 GB) |
| MTP fetch source | `/home/cjdell/Strata/mtp/mtp-q2_0.gguf` + `tensors/` |
| MTP draft runtime | `/home/cjdell/Strata/mtp/rt/` (`experts.bin`, `dense.bin`, `draft_vocab.bin`) |
| Nix package (engine + serve + encoder) | `hosts/zen3-nixos/ai/strata-package.nix`, flake attr `.#strata` |
| NixOS module + nginx | `hosts/zen3-nixos/ai/strata.nix` |
| Vision encoder weights (0.85 GiB) | `/home/cjdell/Models/mmproj-Qwen3.8-Flash-Next-BF16.gguf`, fetched + SHA-checked by `scripts/fetch-strata-mmproj.sh` |
| Service | `systemd` unit `strata`, engine on `127.0.0.1:8080` |
| Log | `/var/lib/strata/strata.log` (plus `journalctl -u strata`) |

Access: nginx owns the IP vhost `/` (the old llama-swap root) and the public
`strata.ai.chrisdell.info` vhost. `llama.ai.chrisdell.info` and
`llm.ai.chrisdell.info` are also answered by the engine (the old names, now
aliases) because the serve layer has a DNS-rebinding Host check:
`allowed_hosts` in the run config must list every public name or nginx gets a
**403** even though the same request on `192.168.49.50` works.

## Preparing the model data (one time, outside Nix)

`apps.strata` only ships the engine and the Python `serve`/`tools`/`data`
layers. The model data is hand-prepared, because the pack tools are not
packaged and need numpy + a `pyyaml`-capable Python + the pinned llama.cpp
`gguf-py`:

```sh
PY=/nix/store/...-python3-3.14.7-env/bin/python3   # the engine's own python
#   (it has numpy; NOT pyyaml/tqdm - those are only needed by mtp_*):
# nix build --impure --out-link /tmp/pyenv --expr \
#   'let f = builtins.getFlake "/home/cjdell/nixos-config";
#        pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
#    in pkgs.python3.withPackages (ps: [ ps.numpy ps.pyyaml ps.tqdm ])'
# Use /tmp/pyenv/bin/python3 for the three mtp_* tools.
export STRATA_GGUF_PY=/nix/store/<llama-cpp-src>/gguf-py   # the pinned rev
cd /tmp/strata-result/share/strata/tools                    # packages.x86_64-linux.strata

# 1. pack: reads every shard, skips the PLE table, writes ~1.5 GB
$PY iq_pack.py --gguf <ggufDir>/...-00001-of-00002.gguf --out /home/cjdell/Strata/pack/iq3s
# (or just `scripts/repack-strata-iq3s.sh`, which wraps the whole thing)

# 2. MTP draft runtime (the GSQ-RCO GGUF ships NO MTP head, so the 31 mtp.*
#    tensors always come from the BF16 checkpoint Qwen/Qwen3.8-Flash-Next,
#    ~4.9 GB, SHA-verified):
$PY mtp_fetch.py fetch --out /home/cjdell/Strata/mtp
$PY mtp_fetch.py verify --out /home/cjdell/Strata/mtp
$PY mtp_pack.py --src /home/cjdell/Strata/mtp --experts q2_0 \
  --out /home/cjdell/Strata/mtp/mtp-q2_0.gguf
$PY mtp_rt.py --gguf /home/cjdell/Strata/mtp/mtp-q2_0.gguf --out /home/cjdell/Strata/mtp/rt
cp /tmp/strata-result/share/strata/data/draft_vocab.bin /home/cjdell/Strata/mtp/rt/
```

The unit has `ConditionPathExists = <packDir>/index.txt`, so it no-ops until
the pack exists (it did during the first switch: "skipped, unmet condition").

The GGUF is the **ISTA-DASLab GSQ-RCO** file. Strata's `iq_pack.py` explicitly
does not support Unsloth's UD-IQ3_XXS (`SUPPORTED_GGUFS`), and the repo has no
VRAM-fitting Flash-Next quant, so this is the one to use.

## Configuration (`hosts/zen3-nixos/ai/strata.nix`)

- `context = 262144` -> `--max-context`; `--kv int8` + `--kv-resident 32768`
  (KV streaming: the whole int8 KV lives in RAM, only 32K cells per QSA layer
  stay in VRAM, so the expert cache does not shrink as context grows).
- `--expert-cache auto`, `--prefill auto`, `--spec 4 --spec-min-p 0.5`,
  `--mtp <rt>`, `--expert-profile <shipped expert-profile.bin>`.
- **Parked conversations (the multi-agent cache), added 2026-10-14:**
  `--conversation-cache-mib 12288 --conversation-cache-slots 12
  --conversation-cache-min-tokens 2048`. Without it the engine keeps exactly
  one live session, so an agent and its subagents alternating requests throw
  each other's KV away and every turn re-reads the whole prompt from token 0.
  Measured on this box before the change (engine `/metrics`): `reused=0` on
  every request that followed a *different* conversation - e.g. 92,571 tokens
  read at ~1.6K tok/s = ~56 s - while consecutive turns of the same one reused
  68-76K of ~75-85K. Parking keeps up to 12 independent conversations in host
  RAM (K/V pages + the ~118 MB/turn checkpoints), matched by exact token/image
  prefix only (no client session id), and restores the one a request continues.
  Cost is host RAM, not VRAM; int8 KV is ~13.7 KiB/token, so a 100K-token
  conversation parks in ~1.4 GB and 12 GiB holds ~8 at 100K or ~3 at 256K; past
  the budget the LRU conversation is evicted, and `--conversation-cache-min-free-mib`
  (default 2560) skips parking rather than forcing it when RAM is short.
  `min-tokens 2048` keeps one-shot probes/titles from spending a slot. Watch it
  on the web Monitor tab's **Conversation cache** card (parked vs slots/budget,
  parks/restores/evictions, tokens reused) or `GET /metrics` -> `"conversation_cache"`
  (`enabled`, `parked`, `restores`, `reused_tokens`). Upstream reference:
  `docs/DETAILS.md` "Multiple conversations (opt-in)".
- The HIP engine only has `gfx1201` kernels, but the box also has the 5700G's
  Vega 8 iGPU, so the run config sets `backend = "hip"` +
  `env.HIP_VISIBLE_DEVICES = "0"` (amd-smi: GPU 0 = R9700, BDF `03:00.0`,
  UUID `47ff7551-…`).
- `allowed_hosts = [ "strata.ai.chrisdell.info" "llama.ai.chrisdell.info"
  "llm.ai.chrisdell.info" ]`.

Change context = edit `context` (or add `--rope-scaling yarn --rope-scale N`
to `engineArgs` for >262144) + `sudo nixos-rebuild switch --flake .`.
zen3-nixos has **no** `autoRollback` (commented out), so no `nixos-confirm`.

## Context / memory ceilings (measured 2026-10-04)

Box: 93 GB RAM, R9700 32 GiB, model on NVMe. All arms: `--kv int8`,
`--kv-resident 32768` except where noted; `--expert-cache auto`.

### What the engine holds

- Experts: **39.97 GiB in RAM** (always) + a **~25 GiB VRAM expert cache**
  (15730 experts at 256K with KV streaming; 13703 / 22.28 GiB without it - so
  streaming is worth ~3 GB of VRAM / ~2000 experts).
- KV: int8 is ~**13.7 KB per token** (12 QSA layers + the draft layer, 1056
  B/cell each); the model's linear (GDN) layers have constant state. At 262144
  that is only ~3.6 GB, at 524288 ~7.2 GB, at 2097152 ~27.4 GB. `--kv-resident`
  keeps it in RAM instead of VRAM.
- RAM used (whole box, steady state): 45 GB at 32K, 47 at 64/128K, 49 at 256K,
  52 at 512K, 59 at 1M, 72 at 2M. The model is bandwidth/RAM-light relative to
  its size because the PLE table is read from the SSD (`--ple-io direct`), not
  held in RAM.

### Fresh-prefill and decode vs context

Single cold request (no prompt-cache reuse), 32 output tokens; prefill is the
engine's own `prompt_per_second`, decode `predicted_per_second`:

| max-context / depth | prefill tok/s | decode tok/s | notes |
| --- | ---: | ---: | --- |
| 32K / 6.5K | 1300-1325 | 35-50 | baseline |
| 32K / 22.7K | 1500 | 65.8 | |
| 131072 / 121K | 1393 | 43.4 | |
| 262144 / 255K | 1184 | 41.0 | native ceiling |
| 262144 / 255K (no streaming) | - | 44.2 | 22.28 GiB cache |
| 524288 / 486K (yarn 2) | **728** | 38.1 | 11 min to ingest |
| 1048576 / 931K (yarn 4) | **376** | 32.0 | **41 min** to ingest |
| 2097152 / 40K (yarn 8) | 1436 | 39.5 | 2M loads, 72 GB RAM |

**The cliff is prefill, not decode.** Decode only drifts from ~40 to ~32 tok/s
across the whole range (QSA's sparse attention keeps decode flat). Prefill
falls roughly as 1/depth past ~128K, so the total time to ingest a fresh
context grows ~quadratically: a 121K prompt is ~87 s, 255K is ~3.7 min, 486K is
~11 min, 931K is **~41 min**. There is no hard wall: 2M still loads and runs
(RAM is the eventual ceiling, ~2-3M at 93 GB). Repeated/incremental prompts
reuse the KV cache, so the quadratic cost is paid once per conversation.

### Recommendation

- **262144** (the model's trained window) is the sweet spot and what
  `strata.nix` sets: no YaRN, ~1180 tok/s fresh prefill (3.7 min for a full
  256K prompt), ~41 tok/s decode, ~49 GB RAM.
- **524288** is the largest of setup's presets and still comfortable
  (~730 tok/s prefill, ~38 tok/s decode, ~52 GB RAM) - use it if the length
  matters more than speed, remembering the 2x YaRN.
- **1M/2M run** but YaRN is 4x/8x (out of the model's training distribution),
  prefill is minutes-to-tens-of-minutes, and 2M leaves only ~20 GB RAM free.
  Not recommended for interactive agent work.

## Vision (image input) — live since 2026-10-15 22:09

The engine takes pictures. OpenAI `image_url` parts and Anthropic image blocks
(base64, `http(s)` and local paths) are decoded by the serve layer, encoded by a
resident **`strata-vision`** helper (llama.cpp's `mtmd` + a ViT), and reach the
engine as float32 embeddings on the `GENI` prompt path with 2-D M-RoPE positions.
Nothing about the text path changes: upstream states the output is bit-identical
with images enabled at equal VRAM, and only prompts that carry image parts are
touched.

Three things were needed, none of them in the engine itself:

1. **Build the encoder.** `tools/vision/CMakeLists.txt` is a *separate* CMake
   project (`add_subdirectory(${LLAMA_DIR} llama)`), so the engine build does not
   produce it and upstream installs nothing — `postBuild` in
   `hosts/zen3-nixos/ai/strata-package.nix` configures and builds it, and
   `installPhase` installs `$out/bin/strata-vision` next to `bin/strata`.
2. **Get the mmproj.** `scripts/fetch-strata-mmproj.sh` pulls
   `mmproj-Qwen3.8-Flash-Next-BF16.gguf` from ISTA's GSQ-RCO repo at the rev
   `setup.py` pins (907,543,008 bytes, SHA-256
   `b1a82259702816a5330d7bd7607cd9676b11780e79ff7348c21103ff3ce49bd0`) into
   `/home/cjdell/Models/`. One file serves every Flash-Next family
   (`setup.py:388/403/413/422` all point at the same repo), so flipping
   `ai.strataModel` needs nothing extra. It is model data, so it is *not* in the
   store, and `ConditionPathExists` now lists it beside the pack index: with a
   `vision` section the serve layer starts the encoder **before** the engine, so
   a missing mmproj would take the whole service down (crash-loop, not degrade).
3. **Raise nginx's body cap.** `strataRootLocation` had no
   `client_max_body_size`, so nginx's 1 MiB default 413'd any phone photo before
   Strata saw it. Now `32m`, matching Strata's own `IMAGE_URL_MAX = 32 << 20`
   (`serve/server.py`).

**The switch is the `vision` section** of the run config
(`hosts/zen3-nixos/ai/strata.nix`): `engine_args()` adds `--vision` to the engine
when the section exists (#1322 — a config with the section but not the flag
advertises images and then refuses every picture), so the generated JSON's `args`
do *not* contain `--vision`; check the engine's own cmdline instead. `gpu = false`
is **forced, not preferred**: `STRATA_VISION_CUDA` is the only GPU backend in that
CMakeLists and `docs/AMD_HIP.md:52/203` says images on HIP go through the CPU
encoder. That costs almost no VRAM — `--vision` alone allocates only the
`(max_context+64)×3` int32 M-RoPE table (`generate.cpp:3201`) = **4.5 MiB** at our
393,216 ctx — and the serve layer's `--vram-reserve-mib 700` is gated on
`gpu = true`, so the 232 MiB of expert cache we have left is untouched. Upstream's
"GPU encoder costs −2..8 % decode" table therefore does not apply here.

### Measured on this box (5950X, 16 threads, BF16 mmproj, UD-IQ4_XS pack)

| Case | Image tokens | Encode | Whole request |
| --- | --- | --- | --- |
| 1024×768 text card (33 KB PNG) | 768 (32×24) | **4.7 s** | **9 s** (837 prompt tokens, 3.6 s prefill, 56 tok/s decode) |
| 930 KB photo, at the `max_tokens = 1024` cap | 1024 | ~25 s | 32 s first, **7.4 s** repeat (same picture is encoded once, #2228) |
| same photo uncapped (standalone, no `--max-tokens`) | 2040 (60×34) | 20.2 s | — |

Correctness: a rendered text card came back as `MEN WALK\nON MOON`, and a real
JPEG was described sensibly ("sunlight filters through a narrow sea cave…").
Encoder peak RSS is 1.2 GiB with flash attention on (the AVX2 case here) / 2.2 GiB
off — transient, but real on a box with the OOM history above.

### The one thing that actually mattered: `-march=native` is silently dropped

Building the encoder the way `setup.py` does on an AMD box
(`-DSTRATA_PORTABLE=OFF`, i.e. "use this CPU") produced a **78 s** encode of the
768-token picture. The same source with `-DSTRATA_PORTABLE=ON` (upstream's own
default, the AVX2 baseline the released encoder ships with) encodes it in **4.7 s
— 16.5× faster**. The reason is in the build log, ~40 times:

```
warning: Skipping impure flag -march=native because NIX_ENFORCE_NO_NATIVE is set
```

stdenv's `cc` wrapper strips `-march=native`, so ggml's *native* path — which is
where `-mavx2 -mfma -mf16c` come from when `GGML_NATIVE=ON` — silently compiled as
baseline x86-64 with no vector extensions at all. `STRATA_PORTABLE=ON` instead
forces `GGML_AVX/AVX2/FMA/F16C/BMI2` per translation unit (`Adding CPU backend
variant ggml-cpu: -mf16c;-mfma;-mbmi2;-mavx;-mavx2`) and keeps AVX-512 off, which
is both reproducible and what upstream benchmarks. **Any future "just build it
native here" flag in this package has to reckon with the same silent strip** — the
engine's own ggml still gets `-march=native` dropped (15 occurrences in the log);
that is pre-existing and untouched, since the engine is GPU/expert-cache bound, but
it is a plausible thread to pull if CPU-side strata work ever looks slow.

### mmproj format: BF16 stays

`docs/DETAILS.md` recommends a Q8_0 mmproj for `--vision cpu`. On this file it
cannot be made — `llama-quantize` refuses:

```
warning: v.blk.0.ffn_down.weight - ncols   4304 not divisible by  32 (required for type    q8_0) llama_model_quantize: failed to quantize: no tensor type fallback is defined for type q8_0
```

`f16` *does* convert (same 907,543,008 bytes) and is ~19 % faster to encode with
(3.99 s vs 4.74 s), but the embeddings drift more than upstream's own quantization
report: per-token cosine vs BF16 mean 0.9989, **worst token 0.650** on a
normal-magnitude token (‖v‖ 1.46 → 2.46), where #625's Q8_0 report claims a worst
token of 0.94-0.96. 0.75 s per picture is not worth an unvalidated format change,
so the F16 file was deleted and the shipped BF16 file is used as-is. Revisit only
with a real OCR/chart benchmark.

### Verifying it

```sh
systemctl is-active strata                       # and ConditionPathExists must hold
pgrep -af '[b]in/strata-vision'                  # the resident encoder + its --mmproj/--model/--max-tokens
sudo tr '\0' '\n' < /proc/$(pgrep -f '[b]in/strata --serve')/cmdline | grep -c -- --vision   # 1 = on
curl -s 127.0.0.1:8080/v1/models | grep -o 'input_modalities[^}]*}'   # ["text","image"]
sudo journalctl -u strata | grep -E 'vision|images on'   # "loading the vision encoder …", "… context 393216 tokens, images on"
```

Or drive it: a base64 `image_url` part to `/v1/chat/completions` should return an
answer about the picture, and `prompt_tokens` should be roughly (image tokens + 60).

## Gotchas

- **A long-context reply can collapse to one repeated token** (or a thinking-only
  turn with no answer). This is the fp16-overflow #606 class, not a model
  quality issue; the quantizer clamps live in `strata-package.nix`'s
  `postPatch`. Full write-up, the two incidents, and the verification commands:
  [`strata-degeneration.md`](./strata-degeneration.md).
- **The engine sometimes stops making progress and kills itself.** A `SIGABRT` +
  core dump is the hang watchdog (upstream #29): `no progress for 60 s during a
  request (reading the prompt (batched): waiting for the GPU (attention, router)
  at layer N …)`, always during long-prompt prefill, and each one is followed by
  an amdgpu MES failure and a MODE1 GPU reset. `NRestarts=0` proves nothing — the
  serve layer restarts the engine in-process. Cores are disabled (`LimitCORE = 0`);
  they were 32 GB and carried no information. Full write-up and the candidate
  fixes (`HSA_USERPTR_FOR_PAGED_MEM=0`, `STRATA_KV_HOST_DMA=1`, `--prefill 512`):
  [`strata-hang.md`](./strata-hang.md).
- **The GSQ-RCO GGUF has no MTP head.** It must always be fetched from the
  BF16 checkpoint (`mtp_fetch.py` needs Hugging Face and is SHA-256 checked;
  a mirror that ignores Range requests is caught by `verify`, exit 3).
- **`iq_pack.py` runs on the engine's python (numpy present) but the `mtp_*`
  tools additionally need `pyyaml`+`tqdm`** - build a small python env for
  them (see above), or they die with `ModuleNotFoundError: No module named
  'yaml'`.
- **`STRATA_GGUF_PY` must point at the pinned llama.cpp `gguf-py`** (it knows
  `Q2_0 = type 42`). The engine package does not bundle it.
- **`-march=native` does nothing in a Nix build** — stdenv drops it
  (`NIX_ENFORCE_NO_NATIVE`), so a "native" CMake option silently means baseline
  x86-64. For `strata-vision` that was a 16.5× encode-time difference; prefer
  flags that set the ISA extensions explicitly (`STRATA_PORTABLE=ON`). Details
  under "Vision (image input)".
- **Making a test image with ImageMagick needs an explicit `-font`.** `magick
  … -annotate 0 "TEXT"` without `-font DejaVu-Sans` renders **nothing at all** and
  exits 0 — three "unreadable" vision test images were blank PNGs, and the model
  was right every time it said there was no text. Check with
  `-format "%[fx:mean]" info:` (1.0 = blank) before believing a vision failure.
- **nginx passes the client's Host header**, and the serve layer 403s unknown
  names: every public name must be in `allowed_hosts` (this bit once:
  `refused a request for Host 'llama.ai.chrisdell.info'`).
- **Use the engine's Python with numpy + the pinned gguf-py**, not the
  system's - there is no `python3` on PATH.
- The first `nixos-rebuild switch` after adding the module shows the service
  as "skipped, unmet condition ConditionPathExists" until the pack exists;
  that is expected, not a failure.
- `# ./llama-swap.nix` and the strata module are mutually exclusive on this
  box: both target the R9700 and tens of GB of RAM.
