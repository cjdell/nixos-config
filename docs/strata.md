# Strata on zen3-nixos (Qwen3.8-Flash-Next IQ3_S)

Status: **live on IQ3_S** (2026-10-06, up from IQ3_XXS). Strata
(`github.com/Niko1221/Strata`) is the engine that runs the ~84 GB GSQ-RCO
model on the 32 GiB R9700 that llama.cpp could only do at ~6.5 tok/s. It
replaces llama-swap on this box (see "Why llama-swap is off" below). This doc
records the install (which is half hand-prepared outside Nix), the config, and
the measured context / memory ceilings that were the point of the exercise.

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
(UD-Q3_K_XL 90 GB, UD-IQ4_XS 94 GB, UD-Q4_K_XL 111 GB); the last does not fit
93 GiB of RAM, and the middle two squeeze the PLE page cache.

When IQ3_S is trusted, reclaim the old files with
`scripts/cleanup-strata-iq3xxs.sh --yes` (~46 GB: shard 1 and the iq3xxs pack;
shard 2 is a hardlink, so unlinking it frees nothing). It refuses unless the
engine is live and serving IQ3_S, and defaults to a dry run.

Upstream pinned: **v0.1.40.3**, rev `d5ea7133741e67743c0e886bb426c0ce8d69cf6c`
(`hosts/zen3-nixos/ai/strata-package.nix`), updated 2026-10-08 from v0.1.40.2
(`e8ca9afd03d839d4f8dbbe82dffce7f8a3bafd7a`). It builds its own ggml from a
pinned llama.cpp (`3cf03257f219afbe7334045ff7c6a06ac68c627d`) — **unchanged by
0.1.40 and 0.1.40.2** (`setup.py:165 LLAMA_CPP_COMMIT`), so `strata-package.nix`'s
`llama` fetch stays as it is.

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
| Nix package (engine + serve) | `hosts/zen3-nixos/ai/strata-package.nix`, flake attr `.#strata` |
| NixOS module + nginx | `hosts/zen3-nixos/ai/strata.nix` |
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
