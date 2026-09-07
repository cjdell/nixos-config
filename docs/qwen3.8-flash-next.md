# Qwen3.8-Flash-Next on the R9700 (qwen4exp + MTP)

Status: **working, deployed** (2026-09-03). All knowledge from getting it
running and then chasing speed — including the "why it can't go faster than
~6.5 tok/s on this box" analysis, so nobody re-runs the dead ends.

## The model

| | |
| --- | --- |
| Architecture (GGUF `general.architecture`) | `qwen4exp` (the Qwen4-experimental design, "Flash-Next") |
| Total / activated params | 125B total, **6B activated per token**, + 51B n-gram ("PLE") embedding, + 4B MTP |
| Layout | 48 trunk blocks of `3×(Gated DeltaNet → MoE) → 1×(Qwen Sparse Attention → MoE)`, + 1 MTP block |
| Attention | Gated DeltaNet (linear) + QSA with an indexer (4Q/1K heads, budget 512 blocks) — sparse |
| MoE | 512 experts, **10 routed + 1 shared active**, expert dim 640 |
| N-gram embedding | `per_layer_token_embd.weight` = **320M rows × 160 dims = 51.2B params (~29 GB)** — read only a few rows per token |
| Context | 262,144 native |
| Quant in use | `UD-IQ3_XXS` ≈ **82 GB on disk** (mixed IQ4_NL 51 GB + IQ2_S 22 GB + Q6/Q8) |

**Crucial sizing fact: nothing in the unsloth repo fits the R9700's 32 GiB.**
UD-IQ1_M = 74.5 GB, UD-IQ1_S = 72.5 GB, UD-Q2_K_XL = 78.9 GB. The Unsloth
"Dynamic" quants for this model floor at ~72 GB (the PLE table + sensitive
tensors stay at higher bitwidths regardless of the quant label). There is **no
VRAM-fitting Flash-Next quant**, so any deployment on 32 GB runs with ≥40 GB
of weights on the slow path. See "The bandwidth wall" below.

## The software maze (as of 2026-09-03) — read before picking a build

Mainline llama.cpp cannot run Flash-Next **MTP**. It can load the model
(qwen4exp base landed upstream in b10715) but:

- no MTP graph for the `qwen4exp` architecture (upstream PRs **#27836**
  "add NextN/MTP draft head" and **#28104** are still open),
- no cross-model draft-head tensor borrowing, so the unsloth **`shared`** MTP
  head files (`mtp-…-shared-Q8_0.gguf`) fail with
  `check_tensor_dims: tensor 'token_embd.weight' not found`, and
- draft-head-only GGUFs (the whole unsloth MTP layout) aren't loadable
  (upstream PR **#28097** "support draft-head-only GGUFs" open).

Then the forks:

| Source | qwen4exp arch | MTP head | Borrowing (shared head) | Base | Verdict |
| --- | --- | --- | --- | --- | --- |
| **unslothai release tag `b10715-mix-86bd2d3`** | **NO** — the release tracks the fork's *master*, which has zero qwen4exp code. Building from source: `unknown model architecture: 'qwen4exp'`. (Their prebuilt binaries presumably come from a different tree.) | — | — | b10715-ish | **useless from source.** Don't add this tag to the flake |
| **unslothai fork PR #144** `mtp/qwen4exp-nextn` @ `b761996` | yes | yes | yes | upstream `662a0b012` (2026-08-31) | **works** (this was the first working build), but base predates the merged upstream decode fixes |
| **ggml-org master** `42f0225` (2026-09-03) | yes | no | no | — | loads the model, `draft-mtp` does nothing / head won't load |
| **local repo `/home/cjdell/Projects/llama-mtp`** = master `42f0225` + **#27836** + **#28097** + backported borrowing (unsloth #144 commit `78ede59e3`) | yes | yes | yes | 2026-09-03 | **deployed. best measured.** |

Why the newer base matters (this is the LocalLLaMA thread's headline): between
Aug 31 and Sep 3 upstream merged **#28123 "qwen4exp: support recurrent state
rollback"** — before it, MTP was *slower than no draft* on prose (83 vs 108
tok/s on the reporter's rig); after it, 144-183 tok/s. Also **#28023 "sum the
indexer heads by slices"** (prompt processing) and more. The unsloth PR branch
lacks all of them. See the r/LocalLLaMA thread in Sources.

### The llama-mtp repo

`git+file:///home/cjdell/Projects/llama-mtp` = ggml-org master (full history,
blob-filtered clone) with, in order:

1. merge of upstream PR **#27836** head (`qwen4exp-mtp`) — MTP draft head;
2. merge of upstream PR **#28097** head (`qwen4exp-draft-fix`) — draft-head-only
   GGUFs (unsloth layout), resolved against master's `n_ff_exp_arr` hparams
   refactor (the PRs predate it: scalar `n_ff_exp` → `n_ff_exp()`, drop the
   duplicate `NEXTN_PREDICT_LAYERS` read that master does generically in
   llama-model.cpp, fix a doubled PLE block);
3. cherry-pick of the **borrowing** C++ bits from unsloth #144 commit
   `78ede59e3` (`model_shared` in llama_model_params/loader + the
   `mparams.model_shared = model_tgt;` hook in `common/speculative.cpp`).

Refreshing after editing the repo: `nix flake lock --update-input llama-cpp-mtp`.
The flake input comment in `flake.nix` carries the full why-not-the-fork story.

## Deployed configuration (hosts/zen3-nixos/ai/llama-swap.nix)

- Flake input `llama-cpp-mtp` (path input above) → `specialArgs.llamaCppMtpPkgs`.
- r9700 router (`llamaCmdR9700Flash`) runs the llama-mtp **Vulkan** build via a
  `llama-r9700-flash` wrapper (`MESA_VK_DEVICE_SELECT=1002:7551!`), with
  `-ngl all` (dropping it defaults to ngl=0 = CPU-only).
- `GGML_VK_ALLOW_SYSMEM_FALLBACK=1` on the service env — required or the 82 GB
  model load fails outright with `unable to allocate Vulkan0 buffer` (see
  docs/gtt-vram.md). Harmless for models that fit.
- MTP preset for the model:

  ```ini
  [Qwen3.8-Flash-Next-UD-IQ3_XXS]
  spec-type = draft-mtp
  spec-draft-n-max = 2        # measured optimum; higher = slower (see sweep)
  md = /home/cjdell/mtp-heads/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf
  ```

- MTP head files live in `/home/cjdell/mtp-heads/` (deliberately *outside*
  `/home/cjdell/Models` so the router doesn't list them as models; the head
  must be passed via `md=` — sidecar auto-discovery doesn't search subfolders).
  **Use the `shared-Q8_0` head (2.6 GB)** — it borrows the main model's
  embedding/lm-head tensors (needs the borrowing support in llama-mtp).
  `self-contained` Q8_0 (3.85 GB) is the fallback for builds without
  borrowing; it measured ~15% slower here (extra 1.3 GB of duplicate weights).

The head is a draft-only export: loading it standalone is rejected
(`borrow_shared_tensor: this model is a draft head…`). One benign error line
at startup from the auto memory-fit probe (`failed to measure the memory of
the extra model, fitting without it`) is expected and harmless — speculation
still runs.

## Performance on this box (R9700 32 GB, PCIe 5.0 x16, Ryzen 5700G)

All decode numbers = 3×200-token completions, temp 0.3, ctx 8192, MTP on with
shared head unless noted.

| Config | tok/s | notes |
| --- | --- | --- |
| **llama-mtp build, `-ngl all`, shared head (deployed)** | **6.50** | 285 verifies / 608 tok (2.13 tok/verify) |
| + `-ot per_layer_token_embd.weight=CPU` | 6.64 | tiny extra; see placement |
| unsloth fork PR #144 build, same shape | 5.84 | 341 verifies/608 (1.78 tok/verify) |
| MTP off (fork) | 4.98 | MTP ≈ +17-30% here |
| self-contained head instead of shared (llama-mtp) | 5.25 | borrowing is worth ~15% |
| `--fit on --fit-target 512` (no `-ngl`) | 4.87 | CPU overflow slower on Vulkan |
| `--lazy-mode auto` | 4.78 | n-gram lazy-offload hurt here |
| `-cmoe` (all experts CPU) | 2.78 | Vulkan CPU path is pathological |
| HIP/ROCm (llama-mtp, gfx1201) + `--fit-target 8000` | 4.96 | HIP has no rebar overcommit; fit→CPU |
| Long-run stability (4×400 tok, temp 0.6) | 6.47 | 1600 tok / 247 s, no errors |

Draft-length sweep on the fork build (n_max): **2 = 5.84, 3 = 5.67, 4 = 5.20,
6 = 4.66** — n_max 2 is optimal (drafting more costs more than it saves on a
bandwidth-bound box). Acceptance: 60-95% depending on sampling (higher temp →
lower acceptance, as the model card warns); long greedy-ish runs ~58-65%, short
runs up to 92-100%.

Prefill: ~81 tok/s on a 4556-token prompt with `-b 2048 -ub 1024 -t 8 -tb 16`
(llama-mtp build; the indexer-sum fix #28023 + ubatch help). ~24 tok/s on tiny
prompts at default batch. A 100k-token agent context still takes minutes to
ingest — prefill is the other half of the story for agent workloads.

### The bandwidth wall (why it caps at ~6.5, and why no flag fixes it)

Per token the model must *read* its ~6B active weights: at the quant's
~3.6 bpw that is **~2.7-3.3 GB/token**. VRAM holds 32 GB of the 82 GB; the
rest is read over the spill path every single token. Effective decode
bandwidth observed ≈ **21 GB/s** (measured: ~330 ms per MTP verify × ~2.15
tokens/verify; PCIe 5.0 x16 is 63 GB/s nominal — the gap is launch overhead
and GTT/chunk churn, not the link). 3.3 GB @ 21 GB/s ≈ 155 ms ≈ 6.5 tok/s.
MTP helps exactly because each *verify* reads the weights once for ~2.1 tokens
(285 verifies instead of 608 single-token decodes).

**Placement experiments that don't rescue it** (all measured, details in
docs/gtt-vram.md):

- The 51B PLE/n-gram table (~29 GB, `per_layer_token_embd.weight`) loads
  *first* in GGUF order and squats most of VRAM even though only a few rows
  are read per token. Forcing it to CPU (`-ot …=CPU`) or lazy (`--lazy-mode
  auto`) frees VRAM but only buys +0-5%: the freed space just gets re-filled
  by other weights that are also only *sparsely* read (512 experts, 11
  active). What you want in VRAM (the ~3 GB of dense per-token tensors) ends
  up there, but the win is small because most of the model is expert/PLE
  weight that spills regardless.
- Vulkan oddity: ggml-vulkan happily allocates **~51 GB of "device" memory on
  the 32 GB card** (rebar overcommit — `used_vram` stays at 32.6 GB, RAM
  +~21-29 GB) and this *beats* every "proper" CPU-offload config. Vulkan's
  CPU-offload path (fit / `-cmoe`) is far worse than CUDA's — on this box
  `-cmoe` drops to 2.78 tok/s.
- HIP/ROCm (the CUDA-equivalent path on AMD) doesn't have the rebar
  overcommit trick: without `--fit` it dies with `cudaMalloc failed: out of
  memory`; with fit (overflow→CPU) it lands at ~5.0 tok/s.
- The Reddit 3060 rig (2×12 GB CUDA) reached 22 tok/s with `--fit` + CPU
  overflow — that recipe does **not** transfer to single-GPU Vulkan/HIP here.
  Don't chase their config; the backend memory story differs completely.

**Bottom line:** 6.5 tok/s is near the practical ceiling for *this model* on a
32 GB card. Real speedups would need (a) a VRAM-fitting model (none exists in
the repo — smallest is ~72 GB), (b) more VRAM, or (c) a working expert-parallel
setup. For fast agents on this box, the VRAM-resident 27B MTP models
(Qwen3.8-27B-UD-*, Dirk-*) are the right tool; Flash-Next is the "slow but
smart" option. `--models-max 1` swaps between them (each swap ~20-30 s).

## What was measured vs. the thread's claims (r/LocalLLaMA, "MTP released for Qwen3.8-Flash-Next-GGUF")

- "Now we just need more llama cpp optimizations merged" → real: #28123/#28023
  landed within hours of the thread and are the biggest single software win
  available (they're in llama-mtp; not in the unsloth PR branch).
- `--lazy-mode auto` (SSD/PLE offload) exists but *lost* ~20% here (page-fault
  / sync overhead on Vulkan; fine on MLX/CUDA rigs with NVMe).
- The 3060 tuner's fit/batch/thread findings (fit-target 512, `-b 1024 -ub
  1024`, `-t 12 -tb 24`) transferred only partially: ubatch 1024 did lift our
  prefill; fit and CPU-thread tuning did not help decode on Vulkan.
- MTP "worth 1.3-1.7x at low concurrency" holds on bandwidth-rich GPUs; here
  it's ~1.2-1.3x because the verify itself is slow-path-bound. Still worth it.
- MTP is a net *loss* at high concurrency (busy model, no idle capacity for a
  draft) — keep the r9700 single-user/low-concurrency for Flash-Next.

## Gotchas / operational notes

- The `--moe-cache auto` flags once appended to `llamaCmdR9700Flash` do not
  exist in any llama.cpp build (`error: invalid argument: --moe-cache`) and
  made the router exit at startup — that was the "upstream command exited
  prematurely" loop. Don't reintroduce.
- `-ngl all` is mandatory in the router cmd (ngl defaults to 0 = CPU-only).
- With the model resident: ~29 GB anon RAM + page cache; VRAM 32.6 GB full.
  The `-cram 65536` budget + 256K ctx KV (~8 GB) still fit with zram cushion,
  but don't expect to co-resident anything else on the R9700 (that's why
  `--models-max 1`).
- Live verification: `curl http://127.0.0.1:8081/upstream/r9700/health`, then
  request `model: "Qwen3.8-Flash-Next-UD-IQ3_XXS`; watch the inner server log
  for `draft acceptance = …` and `/metrics`
  `spec_decode_num_accepted_tokens_total`.
- llama-swap model entries that use this build: r9700 only (rx580/vega still
  run the stock upstream `llama-cpp` Vulkan build).

## How to update llama-mtp (when upstream merges #27836/#28097 or moves on)

Upstream merging the MTP PRs would make llama-mtp obsolete: repoint the r9700
router at plain `llamaCppPkgs.vulkan` (stock `llama-cpp` input) and drop the
local input. Until then:

```sh
cd /home/cjdell/Projects/llama-mtp
git fetch origin            # ggml-org master
git merge origin/master     # resolve; qwen4exp.cpp is the usual conflict spot
cd /home/cjdell/nixos-config
nix flake lock --update-input llama-cpp-mtp
sudo nixos-rebuild switch --impure --flake .
```

## Sources

- Model card + MTP README (flags, head selection, acceptance, n_max guidance):
  https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF and
  https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/blob/main/MTP/README.md
- Reddit thread this work is based on (merged-optimization reports, fit/lazy
  lore, 3060 tuning write-up, MTP-vs-concurrency):
  https://www.reddit.com/r/LocalLLaMA/comments/1w42biu/mtp_released_for_qwen38flashnextgguf/
- Upstream PRs: #27836 (NextN/MTP draft head), #28097 (draft-head-only
  GGUFs), #28123 (recurrent-state rollback, merged), #28023 (indexer heads by
  slices, merged) — https://github.com/ggml-org/llama.cpp/pulls
- Unsloth fork PR #144 (MTP for Qwen3.8-Flash-Next) and its release tags:
  https://github.com/unslothai/llama.cpp/pull/144 and
  https://github.com/unslothai/llama.cpp/releases
- Local research: docs/gtt-vram.md (Vulkan allocation ladder / GTT fallback,
  why no weight cache), docs/multi-gpu-inference.md (layer-split analysis).
