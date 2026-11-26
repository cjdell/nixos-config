# Qwen3.6-35B-A3B at 256K — can it be 100 % VRAM on the R9700? (analysed 2026-11-25, no load tests)

Question asked: can `qwen36-ud-q4-k-xl` serve a **262,144-token** conversation with
**everything in VRAM** (every expert resident — the regime the ~180 tok/s decode
claim depends on) on zen3-nixos? This file is the desk analysis; **nothing here was
tested on the GPU** (kept free for agent traffic) — the numbers come from the pinned
engine's own fit file, the GGUF size on disk, `amd-smi static`, and this lane's
journal. Section *The test later* says what to run when the card is free.

**Verdict: No — not with the `UD-Q4_K_XL` file on disk, at any context above
~145–167K.** It is closed-form, not a risk judgement: weights + 256K KV alone are
**32.83 GiB against the card's 31.86 GiB**, before the engine allocates one buffer.
Full residency at 262144 *is* possible on this card with a smaller quant of the same
family: **`UD-IQ3_XXS` (13.1 GiB) fits with ~4 GiB spare; `UD-Q3_K_XL` (16.0 GiB)
fits with ~0.3–1.1 GiB margin** — the same razor-thin posture Q4_K_XL has at 131072
today. And the trap: **just setting `--max-context 262144` on the current entry
starts with no warning** and silently drops into hybrid (experts-on-CPU) mode.

> **⚠️ 2026-11-25 ADDENDUM (same day, after the bleeding-edge read): the verdict
> above is correct FOR ENGINE 0.1.59.1 AND WRONG IN GENERAL.** The "no KV knob on
> this path" premise — the thing the whole quant-downgrade discussion rests on, and
> the feature request the *Lever* section files upstream — **already exists in
> Strata 0.2.19+**: `--kv fp32|fp16|fp8|fp4` on the q36 own-path engine. With
> `--kv fp4` the cache is 1.65 GiB instead of 11.48, so **UD-Q4_K_XL at 262,144
> lands at ~26.2 of 31.86 GiB, fully resident, on the file already on disk** and no
> quant downgrade is needed at all. Everything below stays valid as the 0.1.59.1
> analysis; read *What the change would be* together with the addendum at the foot
> of this file, which is what got prepared.

## The box (all confirmed 2026-11-25, read-only)

| | |
| --- | --- |
| GPU | AMD Radeon AI PRO **R9700**, gfx1201, `1002:7551`, VRAM `34,208,743,424 B` = **31.86 GiB** (compute-only — the console lives on the RX 580, so the whole card is the q36 lane's when the lease is `llm`) |
| CPU / RAM | Ryzen 9 5950X, 32 threads, **94 GiB** RAM |
| Model | `/home/cjdell/Models/Qwen3.6-35B-A3B-MTP-GGUF/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf` — `22,853,663,008 B` = **21.285 GiB**, MTP block inside the file; `mmproj-F16.gguf` 858 MB beside it (serve auto-adds `--vision`) |
| Lane | `hosts/zen3-nixos/ai/strata.nix` → `models.qwen36-ud-q4-k-xl` (see its long comment), unit `strata-qwen36-ud-q4-k-xl.service` (`:8093`, swap table), run line `--native <gguf> --max-context 131072 --prefill auto --mtp 2`, `parallel = 1`. Engine 0.1.59.1 (pin `0.2.13.1+main-13eedf55`). It **has served real traffic** — journal shows ~6 starts on 2026-11-23 with live tool-calls. |

## The engine's memory model (own_path_fit.py, read from the pinned store build)

`/nix/store/ysnswzz6kmfgq9dyf9j72ki3wn691h3s-strata-0.2.13.1+main-13eedf55/share/strata/strata_control/own_path_fit.py`
carries the formula setup, serve and the app all agree on:

    need(ctx) GiB = BASE_GIB 8.55 + HYBRID_MIN(size) + STATE 0.065 + ctx × 47,104 / 2^30

Parts, and what they mean here:

- **47,104 B/token, hardcoded — there is no KV knob on this path.** 45,056 B is
  **fp32** K+V of **11 KV-bearing layers** = the 10 full-attention layers + the MTP
  block, each `2 KV heads × 256 dim × 2 × 4 B` (`q36_engine.cu alloc_session`);
  2,048 B is one **fp16** K/V staging pair sized at *full context* for prompt
  attention (`Engine::init k16/v16`, reused layer-by-layer). The other **30 of 40
  layers are GDN linear attention** — only a recurrent state, **0.065 GiB/session**
  regardless of context. So: no `--kv int8`, no `--kv-resident` streaming (that is
  the Flash-Next QSA path, a different engine), no `--conversation-cache-*`, no
  rope scaling — and none is needed for the window itself: **262144 is the trained
  length** (unlike Flash-Next's 384K, which rides on YaRN).
- **BASE_GIB 8.55** = dense weights **4.40 GiB** (the fit file calls it the same for
  every size) + engine buffers at a 2048-token prompt chunk + the ROCm context +
  *what Windows keeps of the card*. It is calibrated on **one** RTX 5070 field log;
  the Linux field logs come out at 7.2–7.65, i.e. buffers+context on Linux ≈
  **2.8–3.25 GiB**. Experts add ≈ **16.9 GiB** on top of the 4.40 dense (21.28
  total on disk).
- **HYBRID_MIN 1,256 MiB** (Q4_K_XL) is what hybrid mode allocates *after* evicting
  experts to the CPU pool — a cost of spilling, not of residency.

Two structural facts about what "100 % VRAM" means on this path: the engine places
experts itself (`place_experts` — every one in VRAM where they fit, else the hybrid
mode with `STRATA_Q36_CPU_POOL`), and KV is sized off `--max-context`, not off the
live prompt. So the context number and expert residency compete for the same
31.86 GiB, one-for-one, at 47,104 B/token.

## The 256K arithmetic (UD-Q4_K_XL, every expert resident)

| Component | GiB |
| --- | ---: |
| Weights (experts ≈ 16.9 + dense 4.40 + MTP/emb) | 21.29 |
| KV at 262,144 tokens (262,144 × 47,104) | 11.48 |
| GDN state | 0.07 |
| **subtotal — before any engine buffer** | **32.83** |
| Engine buffers/graphs/ROCm context (Linux est.) | ~3.2 |
| **total** | **~36.0** |
| **Card** | **31.86** |

- Over by **~4.2 GiB** realistically, **0.96 GiB even at zero overhead** — no
  configuration trick recovers it.
- Inverting the budget: KV room = `31.86 − 21.29 − 0.07 − 3.2 (− 0.84 if the vision
  encoder lands in VRAM)` ≈ **6.5–7.3 GiB → ~145–167K tokens** is the full-residency
  ceiling for this file. The last menu step under it is **131072** (KV 5.75 GiB,
  ~1 GiB left on the card) — exactly why `strata.nix` pins 128K, and why upstream's
  quote ON THIS CARD reads *"a 32 GB R9700 at 128K: 4 slots left 15 of 256 experts
  per layer, decode 81 tok/s against ~180"*: residency is already the scarce
  resource at 128K. **204800 does not fit either** (KV 8.98 → ~33.5 total).
- **`--mtp 0` is not the escape.** The MTP block is 1 of the 11 KV layers, so
  killing drafting saves exactly 4,096 B/token = **1.0 GiB at 262K** — still over —
  and pays for it in decode speed (drafting is most of what makes the lane fast).

### Why "just try 262144" is a trap, not an experiment

`own_path_fit.py` predicts *starting*, not residency: `need(262144) = 9.84 + 11.48 =
21.32 ≤ 32` → **no `warning()` is printed**, the strata-swap `vramMinFor` gate
(25,000 MiB free for ownPath, a predecessor-safety margin, not a sizing reservation)
passes, and the engine starts — allocates 11.5 GiB of fp32+fp16 KV, finds ~3 GiB for
experts, and puts most experts per layer in the CPU pool. That is the regime
upstream measured at **81 against ~180 tok/s**. It runs, it is not 100 % VRAM, and
nothing in the startup output announces the loss. (The same reason the `recommended()`
mark can never say more than `DEFAULT_CONTEXT = 131072` — "the mark never goes above
it", owner 2026-11-01.)

## What DOES fit at 262,144 fully resident

Non-weight cost at 262K is 11.48 + 0.07 + ~3.2 ≈ **14.75 GiB**, so the weights must
fit in **~17.1 GiB**. Sizes from the repo's own quant table
(`docs/multi-gpu-inference.md`, unsloth/`Qwen3.6-35B-A3B-MTP-GGUF` — same repo, same
MTP block; the tokenizer pack is size-agnostic, only the repack script touches the
file and that extracts the tokenizer):

| GGUF | Weights GiB | Total @262K | Headroom | Call |
| --- | ---: | ---: | ---: | --- |
| UD-Q4_K_XL (on disk) | 21.3 | ~36.0 | **−4.2** | impossible; full-residency caps ≈145–167K, menu-wise 131072 |
| MXFP4_MOE | 20.7 | ~35.4 | −3.5 | no |
| **UD-Q3_K_XL** | 16.0 | ~30.7 | **+1.1** | fits — same razor-thin posture Q4 has at 128K today; ~0.3 with the vision encoder in VRAM, ~2.1 with `--mtp 0` |
| **UD-IQ3_XXS** | 13.1 | ~27.8 | **+4.0** | the honest comfortable answer: 256K, fully resident, margin for chunks/graphs |
| UD-IQ2_M / UD-IQ1_M | 11.0 / 10.6 | ~25.8 | +6.1 | roomy; MTP acceptance and quality drop here |
| UD-Q8_0 | 35.2 | — | — | weights alone exceed the card |

The quality trade is blunted on this family: 256-expert/top-8 MoE tolerates
Q3-class quants far better than dense models (UD keeps sensitive tensors high —
`docs/multi-gpu-inference.md`).

**The lever upstream doesn't offer (a genuine feature request):** fp32 KV is 45,056
of the 47,104 B/token. q8_0 KV would halve the per-token cost to ~24,576 B → 5.99
GiB at 262K → **Q4_K_XL at 256K fits fully resident with ~5 GiB spare** and the
whole quant-downgrade discussion evaporates. Worth filing on Strata: the own-path
engine is the only one here that cannot quantise its KV.

> **Answered upstream while this was being written (bench dated 2026-11-20,
> shipping in Strata 0.2.19+): `--kv fp16|fp8|fp4` on the q36 path.** fp8 is
> symmetric int8 with one float scale per (KV head, cell); fp4 is q4_0 blocks
> *after a 256-point Hadamard rotation of K and V* (the query is rotated the same
> way so `<Hq,Hk> = <q,k>`, and the output is rotated back). So the
> quant-downgrade discussion below is superseded for any engine we are willing to
> bump — see the addendum at the foot of this file, which is what got prepared.

## Speed caveat from this box's own journal (matters before any of this is chased)

Nov 23, q36 live at 128K, `--mtp 2`, full residency expected: real agent/tool-loop
traffic decoded at **41.6–57.2 tok/s** (prefill ~2,000–2,600 tok/s, unit consumed
49.7 s CPU / 20.7 G RSS peak / 19.1 G read from disk over ~1 min — RAM side is
comfortable). That is a long way from upstream's "~180 solo". Two open candidates:
(a) those log tok/s include thinking + tool-call decode on 24–28K prompts, not a
clean solo stream; (b) **our engine pin 0.1.59.1 predates 0.2.15 / 0.1.60–61 — the
releases q36 actually shipped on** — so 180 was very likely measured on newer
kernels (which carry their own history here: the 2026-11-20 prefill stalls,
`docs/strata-prefill-stall-2026-11-20.md`). Whichever it is, "256K at 100 % VRAM"
should be decided together with the engine-pin question, not in isolation.

## What the change would be (when the card frees — still not applied)

1. Fetch a smaller quant. `scripts/fetch-strata-qwen36-35b-a3b.sh` pins size+SHA for
   **the Q4 file only** (`QWEN36_FILES`) — a Q3/IQ3 file needs a new pin in that
   script (or manual size+sha verification against the HF rev). Tokenizer pack and
   mmproj are reused as-is.
2. `hosts/zen3-nixos/ai/strata.nix`: a models entry (or edit this one) with
   `context = 262144` and `model_name = "qwen3.6-35b-a3b-<size-lower>"` — the
   `qwen3.6-35b-a3b-` **prefix is load-bearing** (`own_path_fit.from_model_name` +
   `FAMILY_MODEL_NAMES`), the suffix is free. Note `HYBRID_MIN_GIB` knows only
   `UD-Q4_K_XL / UD-Q6_K_XL / Q8_0`, so for a Q3/IQ3 size `fixed_gib` returns None
   and **serve's context gate goes deliberately silent** ("the callers keep what
   they did before") — the Nix-written run line is then the only sizing authority.
   Rebuild as usual; swap in via the `model` field or `ai.strataModel`.
3. **The test later** (cheap, self-certifying, and inherently GPU-exclusive like
   every swap): start the unit, read the engine's placement output and
   `amd-smi metric -m --json → gpu_data[0].mem_usage.free_vram` (the 7.2.4 shape
   strata-swap.py already comments on) — full residency vs hybrid is directly
   visible as free VRAM ≈ 3–4 GiB (resident) vs ≈ 0 (spilled). Do NOT infer it from
   tok/s. And per the standing warning in this repo's git history: after any
   `nixos-rebuild switch` that touches these lanes, `systemctl stop strata;
   systemctl start <lane>` as appropriate.

## Addendum — 2026-11-25, later the same day: the bleeding edge, and what got prepared

Everything above is the desk analysis on **our pin (engine 0.1.59.1)** and stands as
such. The premise that made 256K impossible — *"47,104 B/token, hardcoded — there is
no KV knob on this path"* — is no longer true upstream, so the quant-downgrade route
is now a fallback rather than the answer. Read in full: Strata's release notes
0.2.14 → **0.2.21** (2026-11-24, engines/Control 0.1.67), the 0.2.21 `q36_engine.cu`
and `engine/CMakeLists.txt`, upstream's own KV bench, and both of our engine binaries.

### The KV widths exist, and here is the proof rather than the changelog

`--kv fp32|fp16|fp8|fp4` is an option **of the q36 engine itself** in 0.1.6x
(`q36_engine.cu`: the `--kv` branch, `kv_row_bytes/kv_scale_bytes/kv_tok_bytes`
feeding both the allocation and the one-session fit check, `k_attn_part16/8/4` on the
read side, `fwht256_row` for the rotation). Verified without touching the GPU, on the
binaries:

| | pinned `strata` 0.1.59.1 | new `strata-q36` 0.1.67 |
| --- | --- | --- |
| `--kv bogus` | *(no such branch — falls into the catch-all)* | `strata-q36: --kv takes fp32, fp16, fp8 or fp4 (not bogus)`, exit 2 |
| strings: `not an option of this engine` | 1 | 1 |
| strings: `takes fp32, fp16, fp8 or fp4` | **0** | **1** |

That first row is the trap in machine code: on 0.1.59.1 a `--kv fp4` on the run line
prints `ignoring --kv fp4 (not an option of this engine)` and starts anyway.

Upstream's numbers for the same file as here (`UD-Q4_K_XL`, 22.9 GB), from
`docs/bench-results/2026-11-20-q36-kv-precision/README.md`:

| width | KV at 262,144 | KL/step vs fp32 | top-1 same as fp32 |
| --- | ---: | ---: | --- |
| fp32 (default, byte-identical when `--kv` is absent) | 11.56 GiB | — | — |
| fp16 | 6.06 | 0.0044 | 8/8 steps |
| fp8 (symmetric int8, one float scale per KV-head·cell) | 3.35 | 0.0064 | 8/8 |
| fp4 (q4_0, 32-value blocks, **after a 256-point Hadamard rotation** of K, V and the query) | **1.65** | 0.0115 | 8/8 |
| fp4 *without* the rotation (rejected upstream, no switch for it) | 1.65 | 5.19 (max 13.30) | 2/8 — a K-channel outlier flattens 31 of 256 dims |

On this card, same weights (21.29) + state (0.07) + the Linux buffer estimate (≈3.2),
vision off:

| width | total at 262,144 | headroom of 31.86 | call |
| --- | ---: | ---: | --- |
| fp32 | ~36.0 | **−4.2** | the section above: impossible |
| fp16 | ~30.7 | +1.2 | thin — the posture we already distrust |
| **fp8** | **~27.6** | **+4.3** | the safe arm |
| **fp4** | **~25.9** | **+6.0** | the fast arm; expert residency has real room |

**Their fill table is the caveat, and it is the thing to measure.** Same bench:
fp4 74.8 → **4.6** tok/s between 305 and 250,460 cells in one window, fp16 84.3 → 6.8
at 126,367. Read as "this engine's attention is dense split-K with no indexer, so the
cache is read in full every token" — NOT as "256K decodes at 5 tok/s": their card ran
`--expert-vram 0.1`, i.e. experts on the CPU, which is the other half of that number.
Our card holds the whole model, so the question this box has to answer for itself is
the *shape* of the fill curve with everything resident — `scripts/qwen36-256k-check.sh
probe` measures exactly that (short-fill control, long-fill arm, fresh nonce each
time, prompt size reported from `usage.prompt_tokens` and never estimated).

Two more things the read turned up about the gate: `terminal/strata_control/own_path_fit.py`
is **byte-identical between 0.2.13.1 and 0.2.21** apart from an `apps/`→`app/` rename —
the Python fit was never taught the widths, so serve's pre-start warning still quotes
47,104 B/token even for a `--kv fp4` run. Hence the entries' model_name suffix (below):
a name `from_model_name()` cannot parse keeps that gate silent instead of lying.

### What is prepared (nothing deployed; the live lane was never touched)

* **`hosts/zen3-nixos/ai/strata-q36-package.nix`** + `flake.nix` attr `.#strata-q36`:
  Strata **v0.2.21** for HIP/gfx1201 on the ROCm 10 runtime, building **only the
  `strata-q36` target** — whose entire `main` is `return strata::qwen35::run(argc,
  argv)`, "the same entry point `strata` switches to for a qwen35moe model", so the
  Qwen3.8 engine/spec layers never compile. No local engine patches (they are all
  Flash-Next/QSA files), no `strata-vision`, serve from the same tree plus the one
  `server error` rewrite the inkling package proves is unique on v0.2.21.
  **Built clean**: `/nix/store/xxdiv0vxvbfhw6svygrzhzrl37ckccvq-strata-q36-0.2.21`
  (4.2 GB closure).
* **`hosts/zen3-nixos/ai/strata.nix`**: `models.qwen36-256k-fp8` (8096) and
  `-fp4` (8097) — same GGUF as the 128K lane, `--max-context 262144 --mtp 2
  --prefill auto --kv <width>`, `vision = null` (serve adds `--vision` only
  `if isinstance(cfg.get("vision"), dict)`, so the key is a real switch — the
  reader's ~1.3 GiB goes to experts instead), `vramMinMiB = 27000` (the shim then
  refuses the swap instead of starting a doomed hybrid), per-entry `package` /
  `engineBin` / serve so this lane runs engine *and* serve 0.2.21 while every
  Flash-Next unit stays on the pin. Model names carry the width
  (`qwen3.6-35b-a3b-ud-q4_k_xl-fp4`) — the suffix keeps serve's fp32-arithmetic gate
  silent and keeps the swap table's ids unique (new assert). Also fixed the partner
  port allocator to skip ports other modules claim: adding lanes used to be able to
  land on inkling's 8094 / qwen27b's 8095, and would have renumbered q36-128K off
  8093. Verified by instantiation: coder 8092, q36-128K 8093, inkling 8094, qwen27b
  8095, q36-256K 8096/8097, and the generated serve config carries
  `"exe": "…-strata-q36-0.2.21/bin/strata-q36"` + `"--kv": "fp4"` + `"vision": null`.
* **`scripts/fetch-strata-qwen36-35b-a3b.sh`**: `--size UD-IQ3_XXS|UD-IQ3_S|
  UD-Q3_K_XL|UD-IQ4_XS` with size+SHA pins (HF tree API at the *same* revision
  `5bc3e238`, which reproduces setup.py's two existing pins byte-exactly) and a
  guard sized to what is actually being fetched — the fallback route for a pinned
  engine only. **Nothing was downloaded**: `/home` is at 96 % (29 GiB) and with
  `--kv` we do not need another 13-17 GiB to answer the question.
* **`scripts/qwen36-256k-check.sh`**: `status` (read-only), `kv-check` (the table
  above, run live — PASSED), `go fp8|fp4` (refuses while a request is in flight;
  records the live unit for `restore`), `probe` (fill curve), `restore`.

### Why 0.1.67 is also the faster engine for this lane independent of --kv

0.2.20's AMD HIP pass is on the expert formats this engine reads: unified Wave32 WMMA
prefill (70.7 TFLOPS dense, 28.5-36.7 fused dequant-to-LDS) and 6-op `v_perm_b32`
LUT16 Wave32 DP4A decode (451-583 GB/s), plus exact heterogeneous Unsloth per-layer
slot sizing (#4870, #6354). Also in: the #879 24K-45K long-prompt non-finite fix
(#6431, the class we carry local instrumentation for), 0.2.21's "agent sessions reuse
their prompt on every backend", and 0.2.21's #6776 prompt-reading accuracy fix
(answers *can* differ after a few tokens — expected, same speed).

⚠️ **One finding that reaches back to the Nov 23 measurements.** 0.2.17 lists "Qwen3.6
files with K-quant or IQ4_XS `ssm_alpha`/`ssm_beta` load (#3925) and **Q4_K down
experts load (#5595**, 0 failures of `native_grouped_parity` after, a stop before)".
`UD-Q4_K_XL` **is** a K-quant, and our pin predates both fixes. That is a live
candidate for the 41.6-57.2 tok/s recorded above on a lane that should have been at
~180 — and the cheap discriminating test is the same run line at **131072 on 0.1.67**
(same file, same context, only the engine moves). Do it before believing any 256K number.

**Not** in scope, and why the Flash-Next pin stays where it is: nothing in
0.2.18 → 0.2.21 mentions the layers 18-22 prompt-spin / #29-watchdog class
(`docs/strata-prefill-stall-2026-11-20.md`, our #6420) — still open upstream, still
the reason `strata.service` runs 0.1.59.1. 0.2.17's route-tail-skip default change is
a Qwen3.8 knob and does not exist in the q36 engine (no `TAIL` in its source), so it
neither helps nor hurts this lane. And 0.1.67's KV kernels are **CUDA-validated only**
("no HIP or SYCL twin"): they compile and the parser accepts them here, but nobody has
measured fp4 attention on RDNA4 — if fp4 decodes slower than fp8 despite reading 1.8×
less (Hadamard + dequant ALU on 32-lane waves), the fp8 entry is the lane, which is
why there are two entries instead of one guess.

> **The 128K conclusion, and the one that actually changes daily use** is in the
> section below: at 131072 the depth collapse is *entirely* the KV read, so
> narrowing the cache there is worth 3-4x at depth — and 0.1.67's MTP, which was
> dead on the pinned engine (`drafts accepted 0 of 0` on every request in
> `/var/lib/strata-qwen36-ud-q4-k-xl/strata.log`), is worth another +63 % cold.

### Measured on the card — 2026-11-26

The card was free, so all of the above stopped being desk arithmetic. Every number
below is the engine's own `timings` block (`predicted_per_second` for decode,
`prompt_per_second` for prefill), never a wall-clock guess, and every residency
claim is the engine's own placement line plus `amd-smi` free VRAM. Host
zen3-nixos, R9700 31.86 GiB, `UD-Q4_K_XL` 21.29 GiB, `--mtp` as noted, chunk 4096.

**256,144-token window, every expert in VRAM, text-only (no reader):**

| KV width | cache | free VRAM | decode @ 37 fill | @ ~127-138K fill | @ ~253-258K fill |
| --- | --- | --- | ---: | ---: | ---: |
| **fp4** | 0.56 KiB/tok/layer → 1.65 GiB | 2,567 MiB | **165.1** | **48.4** (138,282) | **24.9** (258,136) |
| fp8 | 1.02 KiB/tok/layer → 2.87 GiB | 1,291 MiB | 172.9 | 47.0 (126,786) | 19.6 (252,908) |

Prefill for the same arms: fp4 641 / 774 / 270 tok/s, fp8 681 / 890 / 280. Both
widths load in 20-40 s and both report `every routed expert in VRAM (18.75 GiB)` —
so neither is in the hybrid CPU-expert mode the whole quant-downgrade discussion
was built to avoid. fp4 wins at depth on a *larger* fill, which is what reading
1.75x fewer cache bytes predicts; fp8's advantage cold is inside run-to-run noise.

**131,072-token window, same file, pictures on (the deployed lane's shape):**

| engine | KV | decode @ 37 | @ ~60K fill | @ ~122K fill | prefill @ 122K |
| --- | --- | ---: | ---: | ---: | ---: |
| pinned 0.1.59.1 (Nov 23, from its own log) | fp32 | 107.2 | ~22.5 | ~11.5 | ~800 |
| 0.1.67 | fp32 | **175.2** | 23.2 | 11.8 | 947 |
| 0.1.67 | **fp8** | 178.7 | **75.4** | **49.0** | 947 |

Three separate findings, each worth having straight:

1. **The pinned engine's `drafts accepted 0 of 0` is not a formatting quirk.** MTP
   never fired on 0.1.59.1 for this model, on any request, at any fill. 0.1.67
   accepts 80-88 % of drafts, and that alone is the 107 → 175 tok/s at low fill —
   no attention work changed.
2. **On fp32 KV, 0.1.67 is not faster at depth** (23.2 vs ~22.5 at 60K, 11.8 vs
   ~11.5 at 122K). So the "41.6-57.2 tok/s" recorded on Nov 23 was *not* the
   K-quant loader bug this file suspected in 0.2.17 (#3925, #5595): the same file
   on the fixed engine behaves identically at the same fill. It was the dense
   attention read, exactly as the fill table implies. What 0.1.67 does buy is
   MTP and ~2x prefill at depth.
3. **The KV width is the whole depth story**: at 122K fill, fp8 is 4.15x the fp32
   lane, and 49.0 tok/s at 122K fill beats fp32's 23.2 at half that fill.

Costs worth naming: `/home` is at 96 % (29 GiB free) so nothing here needed a new
quant; fp8 at 256K leaves only 1.29 GiB free, which is why fp4 is the 256K default;
and full-window prefill is slow in absolute terms (258,136 cells in 956 s), so a
fresh 256K prompt costs ~16 min before the first token. Agent traffic reuses its
prefix (0.2.21: "agent sessions reuse their prompt on every backend"), which is the
only reason a 256K window is usable at all in practice.

MTP depth sweep (0 = what the pinned engine effectively ran, 2 = setup.py's pin,
3 = one more draft), 128K fp8 lane, same arms — decode tok/s:

| `--mtp` | draft acceptance | @ 39 fill | @ ~61K fill | @ ~122K fill |
| --- | --- | ---: | ---: | ---: |
| 0 | 0/0 (never drafts) | 110.2 | 58.7 | 40.5 |
| **2** | 91 % | **178.7** | **75.4** | 49.0 |
| 3 | 81 % | 177.6 | 74.4 | **49.1** |

**`--mtp 2` stands** (setup.py's pin was right for this card too): a third draft
adds nothing at depth — 49.1 vs 49.0, i.e. noise — and costs a little cold, with
acceptance falling 91 % → 81 %. Depth 0 is the honest no-drafting baseline: it
reproduces the pinned engine's cold number (110.2 vs 107.2), which is what proves
the pin was effectively running `--mtp 0` all along.

### What to run now

1. `scripts/qwen36-256k-check.sh status` — what is live, free VRAM, which units
   exist. Read-only.
2. `scripts/qwen36-256k-check.sh go fp4` (or `fp8`, `128kfp8`) — GPU-exclusive:
   drains and stops every strata lane, starts the one you named, then measures
   control / mid / near-full arms. It is safe to run while another lane is live;
   it refuses while a request is in flight.
3. `scripts/qwen36-256k-check.sh single MODEL 122000` — one arm, against an
   already-live lane (this is what re-measures an arm that was refused for size).
4. `scripts/qwen36-256k-check.sh restore` — puts back whatever `go` displaced.

Two harness gotchas, both hit and fixed here: a body over 128 KB cannot be passed
through argv (`curl --data-binary "$body"` dies E2BIG, silently measuring nothing —
use `@file`), and random base36 tokenizes at ~0.6-0.7 chars/token, so a fixed
chars/token assumption overshoots the window; the probe now re-sizes from the
engine's own "exceeds the context window: prompt (N tokens)" error and retries.


## Pointers

- The models entry + full rationale for 131072: `hosts/zen3-nixos/ai/strata.nix`
  (`models.qwen36-ud-q4-k-xl`, comment block); swap shim gate `vramMinFor`: same file.
- The 256K entries + their engine: `hosts/zen3-nixos/ai/strata.nix`
  (`qwen36_256k`, `models.qwen36-256k-fp8` / `-fp4`), `hosts/zen3-nixos/ai/strata-q36-package.nix`,
  `nix build .#strata-q36`; measurement: `scripts/qwen36-256k-check.sh`.
- Upstream's KV-width bench (the fill table, the rotation, the KL numbers):
  `docs/bench-results/2026-11-20-q36-kv-precision/README.md` in
  Niko1221/Strata@v0.2.21; the option itself: `engine/src/qwen35/q36_engine.cu`,
  target `strata-q36` at `engine/cmake/strata_gpu_engine.cmake:579`.
- Live-lane bullets: `docs/strata.md` ("Second family, selectable since 2026-11-18").
- Quant table + MTP notes: `docs/multi-gpu-inference.md` (the sizes column there is
  from the same unsloth repo, 2026-08-14).
- Fit formula in the pinned build: `$strata/share/strata/strata_control/own_path_fit.py`.
- Engine pin context: `docs/strata.md`, `docs/strata-prefill-stall-2026-11-20.md`.
