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

Upstream pinned: **v0.1.40.1**, rev `82f46a8c8f475f001ad76d92f58f4a4f8ffb0253`
(`hosts/zen3-nixos/ai/strata-package.nix`), updated 2026-10-06 from v0.1.39
(`6f32ec070f23ced9f50e704d854d775da52591ab`). It builds its own ggml from a
pinned llama.cpp (`3cf03257f219afbe7334045ff7c6a06ac68c627d`) — **unchanged by
0.1.40** (`setup.py:93 LLAMA_CPP_COMMIT`), so `strata-package.nix`'s `llama`
fetch stays as it is.

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
