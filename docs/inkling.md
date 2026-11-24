> Archived from AGENTS.md (2026-11-24). The short version lives in AGENTS.md; this file holds the full backstory.

## Inkling-2-Mini on llama.cpp (`inkling-2-mini.service` — the third swap lane)

Thinking Machines' Inkling 2 Mini (released 2026-11-20, Apache 2.0), served by
**stock llama.cpp HIP (ROCm)** on the R9700 — switched from Vulkan 2026-11-23
because Vulkan's FA path collapses to 22 t/s past ~88K depth (see below) —
Strata cannot run it: the engine's
families are qwen4exp/qwen35moe and `inkling2_loop` (a **looped** transformer:
24 physical layers, layers 6–17 run 3× = 48 layer-visits, 8-of-128 MoE, hybrid
local/global attention, per-expert NVFP4 scales) matches neither. It is a
strata-swap table entry, not a new proxy: `hosts/zen3-nixos/ai/inkling.nix`
publishes it via the new `ai.swapEngines` option (consumed in strata.nix's
`swapConfig`); `ai.strataEngineUnits` gains `inkling-2-mini` so `gpu-mode
sd|game` stops it and `gpu-mode llm` evicts it like the Strata partners. No
`wantedBy` — a reboot still serves `ai.strataModel`; a request naming
`inkling-2-mini-ud-q4_k_xl` on :8080 drains the live engine, swaps units, and
waits (same contract as coder/q36).

- **Run line** (all VRAM knobs documented in the module's header comment):
  UD-Q4_K_XL (17.63 GB, Unsloth's KLD plateau) **fully offloaded**,
  `-c 131072` (NOT the model's 1M: q8_0 KV is 17 408 B/token — 8 of the 48
  expanded cache layers are global, window 1024 for the rest — so 128K costs
  2.2 GB and 384K costs 6.6 GB of a 32 GB card. **Sized to the depth sessions
  actually reach** (~96K here): the reserved-but-unused KV was exactly the
  headroom the prefill scratch needed, and cutting 384K -> 128K measured
  **431 -> 551 t/s** on the same 53.6K prompt. Bump -c only if a session really
  needs it: 2.2 GB of KV per extra 128K),
  `-fa on`, `-ctk/-ctv q8_0`, `--parallel 1`, **`-b 1024 -ub 512`** (`-ub` is
  load-bearing: `-ub 1024` collapses a 53.6K prefill to 128 t/s, `-ub 256` is
  slower still at 32K, `-b/-ub 2048` = 55 t/s, `-b 4096` hangs — see below),
  `--jinja`,
  `--slots`, mmproj-F16 for vision, `--device ROCm0` with
  `HIP_VISIBLE_DEVICES=0` (only the R9700 is HIP-visible — no gfx803 in ROCm 7 —
  so the console card cannot be picked), port 8094 (8091/8092/8093 are strata/coder/q36 — swapConfig asserts port
  uniqueness).
- **Files**: `scripts/fetch-inkling-2-mini.sh` (rev+size+sha pinned) — and it
  must fetch from **`Mainline_Support/`** (`inkling2_loop` tensor layout,
  renamed to `.gguf`): the repo's ROOT UD files use Unsloth's looped layout
  and mainline rejects them. **llama-cpp has two floors for this lane**:
  **b12611** (#32704, 2026-11-20) — older mainline loads the file but silently
  loses the per-expert NVFP4 scales on loop passes 2/3, ppl ~130 instead of
  7.65, no load-time error — and **#32735 (2026-11-22)**, which is what makes
  it usable at all: at b12611 Vulkan's `supports_op` rejects `SCALE` on
  non-contiguous input (`ggml_is_contiguous(op->src[0])` in the
  `GGML_OP_SCALE` arm), so SiTU's two scales per layer — applied to the strided
  gate/up halves of the fused `gate_up` — ran **on the CPU**, 194 graph splits
  per token, and decode sat at **20 t/s**. Upstream's own report is the same
  numbers on the same card (tg128 19.1 -> 53.8, pp512 507 -> 1605).
  `nix flake update llama-cpp` is now also what updates this lane (and
  lfm3/`asus`/`alderlake` at their next switches; the shared floor is the max
  of lfm3's b11960, this b12611 and #32735).
- **BACKEND: HIP, not Vulkan — measured 2026-11-23, same GGUF, same flags**
  (`-ctk/-ctv q8_0`, `-ub 512`), `pp4096` unless noted:

  | depth | Vulkan | HIP |
  |---|---|---|
  | d 0 | 1 069 (pp512) | 1 012 |
  | d 32 K | 505 (pp2048) | 269 |
  | d 65 K | — | 170 |
  | d 90 K | **21.9** | **134** |
  | live full prefill | 139 (95 K, 11.5 min) | **289** (60 K, 209 s) |

  Vulkan's rate is flat-ish to 84 K (**106 t/s instantaneous**, from a live 95 K
  session log) and then falls to **22 t/s by 88 K** — a 5x step, GPU only 48 %
  busy at 294 W. It is **not** memory or KV type, all A/B'd at d90000: q8_0/q8_0
  21.85, q8_0/f16 21.77 (that arm skips the whole-cache dequant copy, so
  `use_dequant_kv` is not the cause), `GGML_VK_DISABLE_COOPMAT2=1` 21.86. HIP on
  the identical prompt: 133.5 t/s at 97 % busy / 207 W, and it allocates the
  card whole (idle = 32.5 GB used, **GTT 95 MiB** — nothing host-resident), so
  there is no cliff. Price: HIP is slower shallow/32 K (269 vs 505). For a lane
  whose live sessions grow past 70 K the trade is obvious: Vulkan's failure mode
  is unusable, HIP's is merely slower.
  The package is `llamaCppPkgs.rocm`, and `flake.nix` overrides
  `rocmGpuTargets = "gfx1201"` for it (nixpkgs' default target list has no
  RDNA4 entry, so without that the card gets no compatible kernels).
- **Measured on this box 2026-11-23** (`a0677c34`, `-b 1024 -ub 512`,
  128K ctx): decode 33-36 t/s (llama-bench tg128 35.7 at depth 0, 27-31 at
  32-49K), and the prefill curve that decides whether the lane is usable:
  pp512 1 069 (depth 0), 877 at 3.5K, 513 at 32K, 421 at 49K, **551 on a live
  53.6K prompt** (431 on the same prompt while `-c` was still 384K; 128 t/s at
  `-ub 1024`), and **139 t/s / 11.5 min for a 95K full re-read**. The
  GPU is genuinely loaded doing it (95 % gfx utilisation, 2.2 GHz, 120-184 W
  sampled mid-prefill), so this is the backend, not a setting:
  * **`-ub 512` is load-bearing, and the cliff is kernel-side, not memory:**
    `-b 1024 -ub 1024` ran that same 53.6K prompt at 128 t/s with the *same*
    total working set (29.5 GB VRAM + 4.8 GB GTT), while `-b 1024 -ub 512`
    does 431 t/s. `-ub 256` is worse (481 at 32K, 900 shallow), `-b/-ub 2048`
    gives **55 t/s** at 32K and `-b 4096` hangs llama-bench outright — never
    use large query blocks on RDNA4. `-b 512 -ub 512` measured byte-identical
    to `-b 1024 -ub 512` (speed and residency), so `-b` need not follow.
  * **A HIP re-sweep on 2026-11-23 showed `-ub 512` is a SHARP optimum, not a
    plateau** — and that the community's RDNA4 batch advice does not transfer
    to `inkling2_loop`. llama.cpp discussion #21043 (gfx1201/RX 9070 XT sweep)
    reports `-ub 2048` = **+29 % prefill** and `-b 16384 -ub 2048` = +48 % on a
    35B MoE, with a dead band at `-ub` 65-256; the common R9700 configs in the
    wild are `-b 2048 -ub 512` (Unsloth Flash-Next) and `-b 2048 -ub 1024`
    (Qwen3.6-35B-A3B). Re-measured here on the ROCm build (`pp2048`, `-r 2`,
    q8_0 KV, the live model, `GGML_CUDA_DISABLE_GRAPHS=1`):

    | `-b`/`-ub` | @d0 | @d65K | @d90K | full 49 152-token prefill |
    |---|---:|---:|---:|---:|
    | 1024/512 (**this**, shipped) | 679 | 171.7 | 134.3 | **329.8** |
    | 2048/512 | 684 | 171.9 | — | — |
    | 2048/1024 | 748 | 171.5 | **timeout >600 s** | 331.8 |
    | 16384/2048 | 658 | **timeout** | — | — |
    | 2048/384 | — | — | **timeout** | 284.4 |
    | 2048/288 | — | — | **timeout** | 239.9 |

    `-b` is irrelevant again (1024 vs 2048 identical); `-ub 1024` buys +10 %
    only on a shallow 2 K prompt and **nothing on a real prefill**, while every
    value other than 512 collapses at depth. 512 is where the FA tile path
    lands right for this model on gfx1201 — treat any other query block as a
    regression until re-measured.
  * **Cost per turn grows with depth even when only a few tokens are new** —
    measured on one live session: 163 new tokens at 92K depth = 2.1 s,
    449 = 5.3 s, 703 = 28 s, against ~1 s shallow. Two causes: per-op FA
    scratch that scales with the tokens in the graph, and (for a QUANTISED KV
    cache) ggml-vulkan's `use_dequant_kv` re-dequantising the **whole cache** to
    f16 before attention on every graph. **`-ctk f16 -ctv f16` is the untested
    candidate**: kv_raw on RDNA4 bypasses the dequant copy entirely, at 2x KV
    (4.5 GB at 128K). Do not assume it wins — A/B it at a fixed depth.
  * **The prefill scratch is depth-proportional: ~140 KB per token of context**
    (+7.7 GB total at a 53.6K prompt), independent of batch shape. Whatever
    exceeds free VRAM is placed in **GTT** silently — at `-c 393216` that is
    ~1.3 GB idle / ~2.6 GB during a 50K+ prefill, and it costs little
    (431 live vs 421 bench with no spill). Shrinking `-c` is the only way to
    buy scratch room: 2.2 GB of KV per 128K, so at `-c 262144` the same
    prefill does not spill at all.
  * q4_0 KV → 471 at 32K, i.e. *worse* than q8_0 (q8_0 is the native FA type,
    so quantising the KV cache does not pay here).
  * llama.cpp's own **ROCm/HIP** backend (built with `rocmGpuTargets =
    "gfx1201"`, `flake.nix`'s `llamaCppPkgs.rocm`; HIP sees the card natively)
    is worse across the board: pp512 1012, tg128 29.2, pp2048@32K **272**.
    Upstream's best published Inkling figure on an R9700 is 893 t/s at 16K
    depth, so "~1000 t/s across a long context" is not reachable on llama.cpp
    here — the levers that actually help TTFT are a **stable prompt prefix**
    (llama-server's LCP reuse turns a warm 50K turn into a 7-token prefill)
    and keeping prompts in the 0-32K band.
  * Earlier, "prefill tanking to 178 t/s with 6 GB in GTT" was **two
    llama-server processes on the card at once** (one orphaned by an
    interrupted benchmark) — two 16.4 GB models cannot share 31.9 GB, so the
    driver shoves the difference into GTT. One server on a clean card sits at
    ~24.4 GB used / 8.2 GB free / 1.4 GB GTT. **Check `pgrep -af
    '[b]in/llama-server'` before believing a GTT number.**
- **Why Qwen3.8-Flash-Next felt flat at 256K and this does not** (the question
  this lane always raises): it is a genuinely different architecture in the one
  dimension that matters. Flash-Next's majority mixer is **gated delta net**
  (linear attention — constant-size recurrent state, *no* depth term; Strata's
  `STRATA_GDN_CHUNKED` is exactly that scan), so most of its layers cost the
  same at 200K as at 2K, and it runs on Strata's hand-fused kernels at ~1 250
  t/s. `inkling2_loop` instead has 24 physical layers run as 48 visits (layers
  6-17 x3), softmax attention throughout (mostly sliding-window 1024, 4 global
  layers whose cost *is* O(depth)), and no engine but generic llama.cpp. Hence
  a 1 069 t/s shallow ceiling that halves by 32K. Practical consequence: long
  prompts are 3-4x cheaper to re-send than to re-read — keep prefixes stable.

- ⚠️ **A `nixos-rebuild switch` starts `strata.service` even while a partner
  engine is live** (strata is `wantedBy=multi-user.target` and the partner
  units have no `wantedBy`), so a switch quietly puts the 90 GB Flash-Next
  engine back on the card alongside Inkling. After any switch on zen3:
  `sudo systemctl stop strata && sudo systemctl start inkling-2-mini` — a
  measurement taken while strata is loading is garbage (a decode read 19.6
  t/s that way, vs 33.6 when quiet).
- ⚠️ **`llama-cpp` is pinned to `a0677c34` (2026-11-23) in `flake.nix`, not
  floating HEAD**: from ~2026-11-20 the upstream flake builds a new Svelte webui
  (`useWebUi ? true`), and that derivation fails in the sandbox
  (brand-favicons `copyfile` EACCES overwriting files in the read-only flake
  source — present at b12611 and at 2026-11-23 HEAD alike). `flake.nix`'s
  `llamaCppPkgs` wrapper now sets `.override { useWebUi = false; }` — which is
  what every llamaCppPkgs build here has always shipped (the classic UI is
  embedded in the binary; the old package had no webui reference). Moving to a
  newer llama.cpp = keep that override until upstream fixes the derivation,
  then restore the floating url and test-build (`#webui` is not a public flake
  output — test through the toplevel).
- **No speculation drafting**: DSpark (`--spec-type draft-dspark`) is still
  open PR #32218 on mainline (unsloth: ~1.1–1.2× when it lands, with the
  Mainline_Support drafter files); `--mtp` does not apply to this model at all.
- **Sampling**: model card = temp 1.0 / top-p 1.0 / top-k 0 / min-p 0 (also
  embedded in the GGUF as `general.sampling.*`); reasoning effort is
  per-request `chat_template_kwargs` (template default `high`). Known quirk
  from the card: it can loop in long reasoning — cap output tokens client-side.
- **strata-swap kinds**: the shim's table entries now carry `kind`
  (`"strata"` default, `"llama"`): liveness/drain via llama-server's `/slots`
  (answered only once the model is loaded; needs `--slots`) instead of
  `/v1/status`, and while a llama engine is live the shim **synthesizes**
  `/v1/status` so `gpu-mode.sh`'s `json_field` parsing keeps working
  unchanged. Name-blind traffic follows the live engine as always — while
  inkling is live, Recallium's nightly runs on inkling.

