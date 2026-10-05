# Strata repeated-token degeneration (#606 fp16-overflow class + #879 data-path defect)

Status: **clamps + a finiteness guard deployed 2026-10-05.** The clamps fixed the
long-context site (the ~132K prompt completes), but a third fire at ~100K and upstream
[#879](https://github.com/Niko1221/Strata/issues/879) showed the underlying defect is a
data-path bug, not fp16 overflow — so a HIP port of the upstream finiteness guard
(binary-attached audit + clean window failure) is now also deployed, and a guard fire
auto-retries (the client reloads the engine and repeats the turn — see "Auto-retry"
below). The
engine is Strata 0.1.39 on the R9700 (HIP/gfx1201), serving Qwen3.8-Flash-Next IQ3_XXS — see
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

`hosts/zen3-nixos/ai/strata-nan-guard.diff` (26 KB, a HIP-adapted copy of the upstream
reporter's `local-patches-20261005-0139b.diff`, generated on our exact pin `6f32ec0`) is
applied as `patches = [ ./strata-nan-guard.diff ]` in `strata-package.nix` — `patches`
run in `patchPhase`, **before** the `postPatch` clamps above, so both apply. It compiles
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

## Still open

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
