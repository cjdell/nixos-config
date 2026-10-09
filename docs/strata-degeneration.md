# Strata repeated-token degeneration (#606 fp16-overflow class + #879 data-path defect)

Status: **clamps + a finiteness guard deployed 2026-10-05; engine switched to
0.1.40.1 on 2026-10-06 14:39 BST.** The clamps fixed the
long-context site (the ~132K prompt completes), but a third fire at ~100K and upstream
[#879](https://github.com/Niko1221/Strata/issues/879) showed the underlying defect is a
data-path bug, not fp16 overflow — so a HIP port of the upstream finiteness guard
(binary-attached audit + clean window failure) is now also deployed, and a guard fire
auto-retries (the client reloads the engine and repeats the turn — see "Auto-retry"
below). 0.1.40 fixed the two q8_1 sites our 0.1.39 build clamped itself and changed
three things upstream says touch #879, so the guard diff and the clamp set were re-based
(see "Update 2026-10-06" near the end). The
engine is Strata 0.1.40.1 on the R9700 (HIP/gfx1201), serving Qwen3.8-Flash-Next IQ3_XXS — see
[`strata.md`](./strata.md) for the install and config. This doc records why a
long-context request can leave the engine answering **one token forever** (and
wiping the agent session that asked), the three incidents on this box, and the
clamps + guard applied in `hosts/zen3-nixos/ai/`.

⚠️ **The clamp family is necessary but not sufficient.** After the 2026-10-05 clamps went in,
the 132,947-token prompt that had failed in incident 2 completed (confirmed, see below), but a
third fire hit at ~100K tokens in the **thinking** channel. That fire matches upstream
[issue #879](https://github.com/Niko1221/Strata/issues/879) (opened 2026-10-05 against the same
revision we pin, `6f32ec0`): the first poisoned value is **garbage bits `0x7FFFFFFF` written into a
routed-expert output row**, i.e. a data-path defect, not an overflowing fp16 scale. The reporter
shows the degeneration still fires on 0.1.39 with *both* q8_1 clamps and with the fused-SwiGLU
quantizer disabled. See "Incident 3" and "Upstream #879" below.

## Symptom

After a long prompt (~100K–156K tokens), the engine's reply collapses:

- it emits a single token repeated (the repeat guard ends the reply after 256);
  seen with `!` (first and third incidents), `索` (second), and — incident 3 —
  inside the **thinking** channel rather than the answer;
- or it spends the whole reply thinking and ends with **no answer** at all
  ("the reply reached max tokens while still thinking, so it has no answer");
- decode speed drops and MTP draft acceptance collapses (e.g. 126/126 → 19/61).

When the client is Pi, `finish_reason: "length"` becomes `stopReason: "length"`
with output (a few hundred tokens) far below `maxTokens` (32768), so Pi treats it
as a *recoverable truncated response*: it omits the turn, appends a
`context_edit` with `replacement: null`, and starts an overflow compact-and-retry.
Because the model produces nothing usable, the retry never recovers — the session
ends looking "crashed" with no further request to the engine (and no Pi
`crashes.json`, OOM, or coredump). See "Client side" below.

## Root cause: fp16 overflow in an activation quantizer

A `q8_1` activation block stores its scale `d = amax / 127` **and** the sum of its
32 activations as fp16 (`block_q8_1.ds`, a `half2`). fp16's largest finite value
is 65504.

- a block **sum** past 65504 (one massive-activation dimension among 32 is
  enough) rounds to `+inf`;
- the scale `d` itself passes 65504 once `amax > 8.3M`;
- the dequantised dot product then reads `inf * 0 = NaN`, and a NaN in the
  residual makes the model emit one token forever.

Upstream tracks this as **#606**; `ggml-org/llama.cpp#23606` is the same defect.
Upstream 0.1.39's fix ("q8_1 activations: keep the block's fp16 scale and sum
finite") clamped two of the three GPU q8_1 quantizers but **missed others**.
`include/strata/kernels/q8_1_finite.hpp` provides the helpers
(`q8_1_finite` / `q8_1_quant` / `q8_1_ds`) that keep a block finite.

The **int8 KV cache** has the same shape: a 64-value group's `amax / 127` is
stored as fp16 with no clamp, so past `amax = 8.3M` the stored scale is `+inf`
and the gather's `q * inf = NaN` poisons attention for every later token. This is
*not* covered by #606 at all, and it is on the long-prompt path
(`prefill/kernels.cu` for the prompt append, `kv_q8.cu` for decode).

## Incident 1 — `!` ×256, ~156K context (2026-10-05, early)

- Journal: `the reply repeated one token ('!') 256 times in a row: ended as
  "length"`, drafts **126/126**.
- Fixed by commit **`437a753`** `strata: clamp the SwiGLU q8_1 quantizer too (the
  #606 fix missed it)`: a `postPatch` that clamps
  `native_swiglu_quantize_q8_1_kernel` in `src/kernels/cuda/native_mmvq.cu`
  (the fused-SwiGLU expert quantizer, introduced by upstream PR #363), using the
  same helpers as its siblings.
- **Deployed**: the live engine is `/nix/store/5na89iv5…-strata-0.1.39/bin/strata`
  (drv `sw1ph3qp…`, which contains the postPatch); the unpatched build
  `nin4vxhg…` ← `ckq75xdi…` differs by **199,052 bytes**.

## Incident 2 — `索` ×256, 132.9K context (2026-10-05 03:10)

- Session: Pi `01a1099d-927e-76ba-87c0-9abc71fa1df9` (cwd `~/Projects/WHY2025`),
  model `strata/Qwen3.8-Flash-Next-IQ3_XXS`.
- Round 0: prompt 132,914 tokens → 149 thinking tokens, `stop`, **no answer**.
  The ACP proxy (`billion-context`) logged a *degenerate terminal turn* and
  retried once with a continuation nudge.
- Round 1: prompt 132,950 → 349 tokens, `length`, token `索` repeated 256 times,
  drafts **19/61**.
- The running engine **already had `437a753`**, so this is a **different site**:
  the q8_1 class was fixed on gfx1201, but the KV-int8 scale (and the gfx906-only
  fused gate/up q8_1 store) were not.

## Incident 3 — `!` ×255 at ~100K, in the *thinking* channel (2026-10-05 05:56 BST)

Same Pi session as incident 2 (`01a1099d-927e-76ba-87c0-9abc71fa1df9`) after it
was restarted against the clamped engine. The session ran ~3 h 45 m (Pi log
`~/.pi/agent/sessions/--home-cjdell-Projects-WHY2025--/2026-10-05T01-11-24-031Z_01a1099d-927e-76ba-87c0-9abc71fa1df9.jsonl`)
and fired once, at the **end of a 4-hour session**, on a prompt of only
**100,134 tokens** — far below incident 1 (156K) and incident 2 (132.9K):

- Pi message `e67117dc`, `2026-10-05T04:56:40.660Z` (05:56:40 BST):
  `role: assistant`, a `thinking` content block of **`!` ×255**, `output: 256`,
  `stopReason: "length"`, `totalTokens: 100390`, `cacheRead: 99889`. Pi then
  appended its usual `context_edit` with `replacement: null` and the session
  ended.
- Engine journal (BST), same second:
  `[strata] the reply repeated one token ('!') 256 times in a row: ended as
  "length" (repeat_stop_tokens in strata-<model>.json; 0 turns this off). If a
  new request with a short prompt does the same, restart the server and report
  it (#606)` followed by `the reply reached max tokens while still thinking, so
  it has no answer`. Entry was read as `100,129 of 100,134 tokens`.
- This fire was on the **patched** engine: `strata.service` restarted
  `2026-10-05 03:31:21 BST`, native binary `/nix/store/xnvr90zm0bm1mhjpdc55a45036g9si9k-strata-0.1.39/bin/strata`
  from drv `5qf1ancdc7sy56rwf9sh1r1762js2na7-strata-0.1.39.drv`, whose env carries
  all four `substituteInPlace` clamps (`q8_1_finite`, `hf_sat`, `kv_q8`).
- **The clamps DID fix incident 2.** On that same restart the recovered
  ~132K request succeeded: journal shows
  `reading the prompt: 90,807 of 132,947 tokens` (03:34:26 BST) →
  `done: 2560 tokens in 149 s (stop, cancel=False)` (03:35:49 BST). So the KV-int8
  clamps closed the long-context `索` site.
- After the fire the engine kept serving other 141K–149K-token prompts normally
  (journal 04:56–04:59 BST), i.e. it was **not** stuck in a global #606 state —
  this is an intermittent ignition, consistent with the upstream reproducer.

## Upstream #879 — this is a data-path defect, not an overflow

[Issue #879](https://github.com/Niko1221/Strata/issues/879) (reporter on an RTX
5090 D, Qwen3.8-Flash-Next, same upstream rev `6f32ec0` = our pin) reproduces the
degeneration **on 0.1.39 with both q8_1 clamps + `repeat_stop_tokens`**, and also
with `STRATA_FUSED_SWIGLU_Q81=0`. Their instrumentation
([gist](https://gist.github.com/66419118nnn/7c9399d982d98229c61fcefaaa0b9215))
localises the first non-finite value:

- It appears in the **routed-expert rows** (MoE path) at a *varying* layer
  (`{3, 13, 15, 16, 18, 20, 22, 26, 28, 37}` across 13 traced fires; GDN and QSA
  layers both), with attention-block output first in one case — so it is not one
  layer's weights.
- In all 6 fires that recorded raw bits the GPU-side value is the **non-canonical
  NaN payload `0x7FFFFFFF`** (four `0xFF` bytes) — not the result of any float
  arithmetic in that path; the miss side saw `0x7FD6E000`/`0x7FD3E000` garbage
  and one canonical `0xFFC00000`.
- Ruled out: precision tier, cache-slot corruption (slot bytes byte-identical to
  the pack file), stale-row instrumentation (the poisoned row is inside the
  engine's `p_dst` plan), GDN/PLE/KV state, CPU pool output, sampling, memory
  overclock.
- Their reproducer fires statistically (~1 in 15–20 tries) at decode positions
  ~77K–88K after a long prefill, and **only** on real agentic traffic with
  process-level cache/swap state; seeds do not transfer across engine restarts.
- Suggested places for the last inch (in `native_expert_grouped` / the window
  graph): `launch_gu`/`launch_down` output-row write coverage vs the plan entries
  and `ent_dst` base offsets (half2/uint4 tail alignment — `0x7FFFFFFF` is the
  all-`0xFF` byte shape); `hit_scratch_`/`nat_xq_` reuse across CUDA-graph
  replays with varying window `T` (`--spec`); the miss-side host-publish →
  mapped-memory read-back and its flag-ring sequencing under graph replay.

**Consequence for this box:** patching more fp16 scale sites (the doc's previous
"next suspects" in `quantize_act.cu` / `s2_expert_grouped.cu`) will **not** close
this. The realistic local mitigations are (a) the upstream **logits finiteness
guard** — fail the window cleanly and dump position/row/bits instead of emitting
`!` — and (b) a client-side repeat guard; the root cause needs the kernel work
above. Note the guard makes the engine exit on a non-finite window (it relaunches
and reloads the ~70 GB model), so it trades a poisoned session for a multi-minute
reload.

## The fix (this session)

All in `hosts/zen3-nixos/ai/strata-package.nix` `postPatch` (substituteInPlace,
bit-identical for finite blocks, NaN stays NaN so `STRATA_DBG_NAN` still sees it):

| # | File | Site | Change |
| --- | --- | --- | --- |
| 1 | `src/kernels/cuda/native_mmvq.cu` | `native_swiglu_quantize_q8_1_kernel` | `d = q8_1_finite(...)`, `q = q8_1_quant(...)`, `ds = q8_1_ds(...)` (from `437a753`) |
| 2 | `src/kernels/cuda/iq_kernels.cu` | `native_gu_fused_kernel` (mode 7) | same three, via `q8_1_*` — **latent**: its launch is under `STRATA_HIP_GFX906`, off for gfx1201 |
| 3 | `src/kernels/cuda/kv_q8.cu` | `kv_append_q8_kernel` | clamp `amax / 127` before `f16_from_f32` |
| 4 | `src/prefill/kernels.cu` | prompt int8 KV append | `hf(amax / 127)` → `hf_sat(amax / 127)` |

Sites 3 and 4 are the leading explanation for incident 2: they run during prompt
prefill of a long context, exactly when the degeneration started, and were never
touched by #606.

### The clamp set on 0.1.40.1 (2026-10-06)

Checked against the 0.1.40.1 tree, not the changelog:

| # | File:line | Site | Status on 0.1.40.1 |
| --- | --- | --- | --- |
| — | `src/kernels/cuda/native_mmvq.cu:172` | `native_swiglu_quantize_q8_1_kernel` | **fixed upstream** (0.1.40: "the fused SwiGLU q8_1 quantizers keep their scale finite") → our clamp **deleted**; its target strings are gone, so keeping it would fail `--replace-fail` |
| — | `src/kernels/cuda/iq_kernels.cu:3342` | `native_gu_fused_kernel` (mode 7) block store | **fixed upstream** (`q8_1_ds`) → our clamp **deleted** |
| 1 | `src/kernels/cuda/iq_kernels.cu:2326-2330` | `s26_swiglu_q8_1_kernel` (new S26 fused swiglu+q8_1) | **ours, latent**: behind `STRATA_EXPERT_V2`, which 0.1.40 turns on by default only on gfx1151 (`src/core/arch_defaults.cpp`), not on gfx1201. Clamped with `q8_1_finite/q8_1_quant/q8_1_ds` for the same reason the old gfx906-only site was |
| 2 | `src/kernels/cuda/kv_q8.cu:55` | `kv_append_q8_kernel` int8 KV scale | **ours, live** — still unclamped upstream |
| 3 | `src/prefill/kernels.cu:1340` | prompt int8 KV append | **ours, live** — still `hf(amax / 127)`, clamped to `hf_sat(...)` |

Deliberately **not** clamped (same fp16-ds class, but opt-in and off on gfx1201, and
the clamp family is not what closes #879): `fused_gr.cu:198` (`gr_q8_tail`) and
`verify_kernels.cu:184` (`gdn_q8_1_store`), both behind `STRATA_QFUSE` — `qcnt_` is only
allocated under `g_qfuse()` (`verify.cpp:597`), so neither runs on this box. Re-visit if
`STRATA_QFUSE` is ever turned on. Also still unclamped and not ours to fix: the CPU-side
`kernels/cpu/expert.cpp:94` and `core/native_dense.cpp:70` (fp32 scales, no fp16 store).

### Verification

```sh
# the unit and the store paths it runs
systemctl show strata -p ExecStart --value
readlink /proc/$(pgrep -f 'bin/strata --serve')/exe    # must be the new store path

# the config the engine was started with (its "exe" field is the real binary)
cat /nix/store/<hash>-strata-iq3xxs.json | tr ',' '\n' | grep exe

# confirm a derivation carries the postPatch (a build without it prints nothing)
nix derivation show /nix/store/<drv>.drv | grep -o 'q8_1_finite\|#606 (SwiGLU)'
```

`bin/strata-server` is only a 267-byte wrapper; compare the **native** `bin/strata`,
not the wrapper (the wrapper differs by 32 bytes of embedded store paths alone).

## Finiteness guard — deployed 2026-10-05 (mitigation + instrumentation)

`hosts/zen3-nixos/ai/strata-nan-guard.diff` (430 lines, a HIP-adapted copy of the upstream
reporter's `local-patches-20261005-0139b.diff`) is applied as `patches = [ ./strata-nan-guard.diff ]`
in `strata-package.nix` — `patches` run in `patchPhase`, **before** the `postPatch` clamps
above, so both apply. It was generated on our 0.1.39 pin `6f32ec0` and **re-generated on
2026-10-06 against `82f46a8c` (0.1.40.1)**; see "Update 2026-10-06" below for what had to
move. It compiles
on gfx1201/HIP unchanged (pure `cuda*` shims + `<<<>>>`, `atomicCAS`, device `memcpy`,
`isfinite` — all already used by the tree).

Two independent behaviours:

1. **Guard (on by default; `STRATA_NAN_GUARD=0` disables).** `Verifier::run` scans the
   window's `head_logits_` for non-finite values via `logits_nonfinite` into a flag that
   rides in `m_out_`'s spare int, read after the sync the path already did (no extra
   sync). On a hit it prints
   `strata verify: non-finite logits at position <p>, rows <T> (window failed rather than
   sampled)`, sets `err = "verify: non-finite logits"`, and **returns false** — so the
   engine prints `strata generate: verify: non-finite logits` and **exits rc 1**
   (`src/program/generate.cpp:8039-8041` and the prefill/decode callers). The serve layer
   sees the exit (`serve/server.py:550-553` `The engine exited (code 1)`) and restarts it
   on the next request — i.e. **a fire now costs a request error + a ~30 s–1 min model
   reload, instead of poisoning the session with `!`.**
2. **Audit (`STRATA_KERNEL_AUDIT=1`, set in `strata.nix` `configFile` env; costs an extra
   scan per stage per layer, mostly prefill).** On a guard hit it dumps, to stderr:
   `layer trace: first poisoned <name> at layer <l>` for seven signals (input, attn
   block, shared expert, routed total, combined, GPU cache-hit rows, CPU miss rows);
   `first non-finite MISS value` and `... HIT value` (row/token/slot/col/`bits 0x%08x`);
   `kernel-stage audit: first non-finite in <gate|up|swiglu|down out> of layer <l>`; and
   `planned-GPU-row audit`. The raw bits are what confirms whether we match the CUDA
   reporter's `0x7FFFFFFF` routed-expert garbage (`native_stage_audit_*` in
   `iq_kernels.cu`, `audit_hit_rows`/`record_first_nonfinite` in `sampler.cu`).

This is **mitigation + diagnosis, not the root-cause fix** — it turns a silent poisoned
session into a clean, logged failure and should give us our own bits. The
`native_expert_grouped` data-path defect itself is still open upstream.

Deployed build (verify with `systemctl show strata -p ExecStart --value` and
`readlink /proc/$(pgrep -f 'bin/strata --')/exe`):
`/nix/store/nn01k1m5f0v9fp8w1mxq0f0zik66p89m-strata-0.1.39/bin/strata`
(from drv `9py3prk33j8wc1xf5kn1pxm1wqlr4wn5-strata-0.1.39.drv`), engine env
`HIP_VISIBLE_DEVICES=0 STRATA_KERNEL_AUDIT=1` (verified in `/proc/<engine>/environ`).
A normal short request still completes (tested: 42.8 tok/s, MTP 13/22 accepted, no trip).

On a fire, grep the journal for:

```sh
journalctl -u strata --since '-2 days' | grep -E 'strata verify:|kernel-stage audit|non-finite (MISS|HIT)|layer trace|strata generate: verify'
```

## First guard fire (2026-10-05 12:47 BST) — a HIP-specific signature

The first live guard trip after deployment. The engine had started 11:55:51 BST and
fired ~51 min in on a **Pi agent session**; the client saw `Error: verify: non-finite
logits`, and the serve layer logged `[strata] the engine reported an error: verify:
non-finite logits`. The engine exited rc 1 — a clean window failure, exactly the
designed trade (a lost turn + a ~30 s–1 min reload instead of a poisoned session).

`/var/lib/strata/strata.log`:

```
strata verify: non-finite logits at position 114609, rows 4 (window failed rather than sampled)
strata verify:   mapped miss rows: 0 of 102400 non-finite, max|x| 0; first at row -1 col -1, bits 0x00000000
strata verify:   layer trace: first poisoned input at layer 5 (GDN)
strata verify:   layer trace: first poisoned attn block at layer 4 (GDN)
strata verify:   layer trace: first poisoned shared expert at layer 4 (GDN)
strata verify:   layer trace: first poisoned routed total (hits+misses) at layer 4 (GDN)
strata verify:   layer trace: first poisoned combined at layer 4 (GDN)
strata verify:   layer trace: first poisoned GPU cache-hit rows at layer 4 (GDN)
strata verify:   layer trace: first poisoned CPU miss rows at layer -1 (-)
strata verify:   first non-finite HIT value: row 0 (token 0, expert slot 0), col 1024, bits 0x7fc00000
strata verify:   kernel-stage audit: first non-finite in gate (gu kernel) of layer 47, flat 9728, bits 0x7fc00000
strata verify:   planned-GPU-row audit: layer 4, row 20 (token 2, slot 0), col 0, bits 0x7fc00000, expert 0
strata serve: verify: non-finite logits
```

**This is not the CUDA reporter's signature.** Every local probe carries
`0x7fc00000` — the **canonical positive quiet NaN** (exponent `0xFF`, mantissa
`0x400000`) that a GPU produces for an invalid arithmetic op (`0/0`, `inf−inf`,
`inf·0`), identical at all three sites (HIT value, gate `gu` kernel layer 47,
planned-GPU-row layer 4). #879's reporter saw the **non-canonical all-ones payload
`0x7FFFFFFF`** (exponent `0xFF`, mantissa `0x7FFFFF` — the byte shape of `INT32_MAX`
reinterpreted as float, i.e. a sentinel/garbage write) in routed-expert rows, plus
`0x7FD6E000`/`0x7FD3E000` garbage and one `0xFFC00000`. On HIP the poison is therefore
an ordinary qNaN from real math, not a garbage-bit write.

**Localisation:** the CPU/miss path is completely clean (`0 of 102400` non-finite) — it
is the **GPU expert-cache HIT rows** that first go non-finite, and the earliest layer
trace is **layer 4 (GDN)** for attn/shared-expert/routed/combined (input first bad at
layer 5), with one gate (`gu` kernel) probe at layer 47. That narrows #879's named
suspects for this build to the GPU-side cache-hit expert path (`native_expert_grouped`
/ the cache-hit row write), not the CPU miss publish.

## Auto-retry (2026-10-05) — a guard fire now reloads and repeats the turn

The guard's clean failure still ended the **session**, because the client (Pi) never
retried it. Pi's agent-level auto-retry (`retry.enabled`, on by default) classifies a
provider error from the message **text alone** (`isRetryableAssistantError` in
`@earendil-works/pi-ai/dist/utils/retry.js`: a regex of transient patterns such as
`server.?error`, `503`, `timeout`, `terminated`). The guard's message is exactly
`verify: non-finite logits`, which matches **none** of them, so Pi marked it
non-retryable and stopped. Confirmed in the failing session
(`2026-10-05T01-11-24-031Z_01a1099d-927e-76ba-87c0-9abc71fa1df9.jsonl`): its last line
(1374/1374) is `{"role":"assistant","stopReason":"error","errorMessage":"verify:
non-finite logits"}`, with no `auto_retry_start` event anywhere.

**Fix:** `hosts/zen3-nixos/ai/strata-package.nix` rewrites the serve layer's
mid-stream error bodies so the message begins `server error: ` — both the engine's
post-stream `ERR` (`ValueError`) and the `EngineDied` path. It lives in the
package's **`installPhase`**, not `postPatch`: `installPhase` copies the Python
layer from the pristine `${finalAttrs.src}`, so a rewrite of the build tree's
`serve/server.py` never reaches the installed package (the C++ binary does use the
build tree, so the clamps stay in `postPatch`):

```python
# serve/server.py (openai path)
err = {"error": {"type": "server_error", "message": f"server error: {e}; the next request restarts it"}}
err = {"error": {"type": "server_error", "message": "server error: " + str(e)}}   # headers are sent, so no 400 now
```

Pi's `server.?error` pattern matches, so it now schedules its normal backoff retry,
which **re-sends the whole turn**. The retried request lands in
`StrataEngine.ensure_loaded()` -> `restart()` (`serve/server.py:1773`/`577`), which
**blocks until the engine says READY (~30–60 s)** before prefill, then the turn runs
again. The engine's own error string and the `strata verify: …` audit lines are
untouched; only the API-boundary message changes. Default Pi retry settings
(`maxRetries 3`, `baseDelayMs 2000`) already suffice because the retry blocks through
the reload; bump `maxRetries` if several consecutive fires are a concern.

**Cost of a fire is now:** a ~30–60 s reload + a full re-prefill of the conversation
(the engine's KV/reuse cache is gone with the process; a 100K-token context is
~1.5–3 min at ~1000 tok/s), plus Pi discarding the poisoned turn. The turn continues
by itself — no user action, no lost session.

## Update 2026-10-06: 0.1.40.1, upstream's answer, and the patch re-base

**Our #879 follow-up was posted** (issue #879 comment, 2026-10-05T10:51:41Z — the
HIP/RDNA4 data point, the full clamp set in place, the 100,134-token thinking-channel
fire, and the note that the clamps closed the 132.9K site). It linked
`hosts/zen3-nixos/ai/strata-package.nix` as our workaround. It predates the first
guard fire (12:47), so the `0x7fc00000` HIP raw-bit signature has **not** been posted.

**Upstream's reply (2026-10-06T06:41:22Z):** 0.1.40 changes three things that touch
this — (1) the residency-table uploads wait for their own copy before the verifier
reads the table (PR #550), (2) a window no longer runs the 100 %-resident graph while
any expert is out of VRAM (#871), (3) a Stop sent during the prompt read now reaches
the engine at once. They ran *stop → edit → resend* 8× on 0.1.39 and 8× on 0.1.40
(Q2_0, partial residency, RTX 5070, `STRATA_DBG_NAN=1`) and saw **no degeneration and
no non-finite values**, so they could not reproduce it. Their ask: **retry on 0.1.40**,
if it still fires send the log with `STRATA_DBG_NAN=1`, and try `--adapt-every 100000`
and **no** `--resident-budget-gib` (we pass neither, so only the retry is actionable).

**The reporter's addendum (2026-10-05T03:55:09Z)** — worth keeping because it changes
how a fire should be read: a near-deterministic repro (send a long task → hit **Stop**
→ the engine keeps generating through the "stopped" window → edit → resend; degenerates
into `!` spam within a few rounds, on three different clients), the `0x7FFFFFFF` =
`INT32_MAX` sentinel-as-float hypothesis, a **deferred-abort teardown/setup race**
(request N's teardown runs while N+1 reuses the same buffers), and the claim that the
poison is **session-scoped, not engine-global**: a new session recovers without
reloading, because the `!` tail sits in that session's KV and self-sustains. Their
suggested fix direction is KV-block epoch/canary checks and *auto truncate-KV-tail +
regenerate* rather than a fatal guard. Our own incident 3 (a fire at 100K with 141K–149K
prompts serving fine right after) fits that model.

**What moved in the guard diff.** Applied to 0.1.40.1 unchanged, 6 of its 11
`src/core/verify.cpp` hunks fail: 0.1.40 added the `STRATA_QFUSE` fused-read return
values (`const bool q8_attn = gr_read_group(...)`, `const bool q8_ffn = ...`), the S26
kernels, the #871 all-resident plan error after the sync, and new arena buffers
(`arg_scratch_`, `one_`, `ple_key_/ple_val_`) between `head_logits_` and `hist_snap_`.
The `iq_kernels.cu` (stage audit), `sampler.cu` and the three header hunks apply with
pure offsets (+926 … +955). The re-base re-anchored those six by hand and the diff was
**regenerated from the patched tree**, so it now applies with `--fuzz=0` and reproduces
the tree byte-for-byte.

⚠️ **Do not re-apply this diff with fuzz.** With `--fuzz=3` patch "succeeds" and puts
the arena `carve` insertion *inside the `mapped(...)` chain* and the input audit *inside
the PLE `try` block* — it looks applied and is wrong. Always `patch -p1 --fuzz=0` and
fix rejects by hand.

**Build check (2026-10-06, `nix build .#strata`, no switch):**
`/nix/store/vl353xnf6ccdlckjs2mm8j428s6zp28s-strata-0.1.40.1/bin/strata` from drv
`qrbdsi6a6ygl3mhzsyk5x052qd7szs7x-strata-0.1.40.1.drv` (HIP/gfx1201, build phase 2 min
8 s, 11.18 MB vs 9.01 MB for 0.1.39). Verified: `patchPhase` patched all 6 files with no
`.rej`; the binary carries `verify: non-finite logits`, the `strata verify:   layer
trace: …` / `kernel-stage audit: …` / `planned-GPU-row audit: …` format strings and the
`native_stage_audit_*` symbols; the drv env carries the three remaining clamps; the
installed `serve/server.py` carries the `"server error: "` prefixes at lines 4242 and
4250. `--replace-fail` is a build failure if a clamp string is missing, so a green build
*is* the proof the clamps landed.

**`STRATA_DBG_NAN=1` — do not enable it permanently.** Upstream asks for it on a fire,
but in `verify.cpp` it copies the whole `head_logits_` (`T × n_vocab` ≈ 2.4 MB) D2H on
every window *until it has reported once* (`static bool reported`), i.e. a blocking
per-window copy on the decode hot path forever if nothing fires. Our guard's GPU-side
flag is the cheap equivalent; set `STRATA_DBG_NAN=1` only for a deliberate diagnostic
run.

## Update 2026-10-08: 0.1.40.2 → 0.1.40.3, nothing we rely on moved

Re-checked against the `v0.1.40.3` tree (`d5ea7133`, built
`/nix/store/mcvch76h0ab3icsxxvrns58cz76qc21x-strata-0.1.40.3`; live engine is still
0.1.40.2 until the next switch). 28 files differ from 0.1.40.2 and **none of them is a
patched file**: `verify.cpp`, `sampler.cu`, `iq_kernels.cu`, `kv_q8.cu`,
`prefill/kernels.cu` and `serve/server.py` are byte-identical, so the guard diff applies
with `--fuzz=0` unchanged, the three clamps are still at `iq_kernels.cu:2326-2330`,
`kv_q8.cu:55` and `prefill/kernels.cu:1340` (still unclamped upstream), and the
`"server error: "` rewrites still land at `serve/server.py:4741`/`:4749`. Upstream did
**not** touch the `native_expert_grouped` data path #879 blames, and the issue is still
open (last maintainer reply 2026-10-07: cannot reproduce, retry on 0.1.40). The only
near-miss for us is #1357 (`mtp.cpp`: the native top-10 router is now gated on
`g.n_expert == 512 && K == 10`) — our pack matches, so the MTP path is unchanged.
Details in [`strata.md`](./strata.md).

## Update 2026-10-09: 0.1.40.3 → 0.1.41, one clamp handed back, two still ours

Re-checked against the `v0.1.41` tree (`fb58e0d0`, built
`/nix/store/ap1x4fnmjwvmirrjp3d02x58s9vgj122-strata-0.1.41`; live engine is still
0.1.40.3 until the next switch). 105 files differ, and this time two of them are
patched files — `verify.cpp` and `iq_kernels.cu` — but the guard diff still applies
with `--fuzz=0` and **offsets only** (`verify.cpp` +35/+43, `iq_kernels.cu`
+72/+80; `sampler.cu` and all three headers byte-identical), landing in the same
`Verifier::run`/`record_window` and `native_expert_grouped` bodies.

- **Upstream #1448 clamped our clamp (1).** `iq_kernels.cu` `s26_swiglu_q8_1_kernel`
  (2323-2330) now uses `q8_1_finite/q8_1_quant/q8_1_ds` exactly as our `postPatch`
  block wrote it, so that block is deleted from `strata-package.nix` (its
  `--replace-fail` targets no longer exist). #1448 also clamped
  `verify_kernels.cu gdn_q8_1_store` and `fused_gr.cu gr_q8_tail` — the two
  `STRATA_QFUSE` sites we deliberately left, which closes that "re-visit if
  STRATA_QFUSE is turned on" note.
- **The int8 KV sites are still unclamped upstream, still ours:** `kv_q8.cu:55`
  (decode) and `kv_append_kernel`, `src/prefill/kernels.cu:1691` (prompt; moved from
  1340). Both live because we run `--kv int8`.
- **Nothing touched the #879 suspects.** `native_expert_grouped`'s `launch_gu` /
  `launch_down` bodies changed only inside `#if STRATA_EXP_LAYOUTS`, which is 0 for a
  gfx1201 HIP build, and `verify.cpp` changed only for the opt-in
  `STRATA_ROUTE_RESIDENT`. #879 is still open (last update 2026-10-09). The guard and
  the two remaining clamps stay.
- **New watchdog layers, neither a fix for our fires:** the engine's #29 watchdog now
  allows up to `STRATA_WATCHDOG_IO_S` (default 10× 60 s) while the file tier is still
  being read (#1407), and the server ends/restarts an engine silent for
  `STRATA_ENGINE_STALL_S` (90 s) with no CPU/disk/GPU activity (#1317; needs psutil,
  which our derivation bundles). Full notes in [`strata.md`](./strata.md).

## Still open

- **Retry #879 on 0.1.40.1 — in progress.** Switched 2026-10-06 14:39 BST: the live
  engine is `/nix/store/vl353xnf6ccdlckjs2mm8j428s6zp28s-strata-0.1.40.1/bin/strata`
  (0.1.39 `/nix/store/nn01k1m5…` is now only a generation). Watch for a
  `verify: non-finite logits` fire. If it fires, capture the audit lines and post them
  (our `0x7fc00000` GPU-cache-HIT signature is still unposted upstream). If it does
  *not* fire again over long agentic sessions, #879 is plausibly closed for HIP by the
  #550/#871/Stop fixes.
- **Confirmed (partly).** The clamp fixed the incident-2 long-context site (the
  ~132K prompt now completes). But incident 3 at ~100K, and upstream #879, show
  the general degeneration is a **GPU routed-expert data-path defect** that the
  clamp family cannot close. Do **not** keep adding fp16 clamps expecting a fix —
  the reporter disabled the fused-SwiGLU site and still fired.
- **(a) Done — guard deployed 2026-10-05, and the first fire is captured** (see
  "First guard fire" above): a bad window now fails cleanly with position +
  per-stage layer/row/col/raw-bits. Our bits **do not** match the CUDA reporter's
  `0x7FFFFFFF`/`0x7FD6E000` — ours is the canonical qNaN `0x7fc00000`, first in the
  GPU expert-cache HIT rows of layer 4 (GDN). **Next:** post the HIP signature to
  #879 (it points at the GPU cache-hit path, not the CPU miss publish).
- **(b) Root cause still upstream.** The `native_expert_grouped` `launch_gu`/`launch_down`
  row-coverage / `ent_dst` / graph-replay-reuse defect (#879's named suspects) needs an
  upstream kernel fix; the guard does not prevent the poison, only its escape.
- **Sticky state.** Upstream warns that a *short* prompt repeating after a long
  one means the engine is in the #606 state; that requires an engine reload
  (`systemctl restart strata`, then wait out the multi-minute model load). The
  new clamps should stop the state occurring, but this is the stopgap.
- **Folded reply, not engine crash.** Pi's `isRecoverableLength` +
  overflow compact-and-retry is what made a bad reply look like a crashed
  session. A future Pi-side guard could detect a response whose content is one
  token repeated N times and surface it instead of retrying. The 0.1.39 server
  guard already ends the reply after 256 repeats (`repeat_stop_tokens`), so the
  damage is bounded to a lost turn, not a wedged session. **2026-10-05 follow-up:
  guard fires are now auto-retried** (see "Auto-retry" above) — the client reloads
  the engine and repeats the turn instead of stopping, so a fire no longer ends the
  session.
- **Reasoning budget.** `serve/server.py` suggests `reasoning_budget_tokens`
  (run config or request) so thinking cannot consume the reply budget. Not set
  today, because incident 2's round 0 stopped at 149 tokens, not at the cap, so
  a budget would not have changed it.
