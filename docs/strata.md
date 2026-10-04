# Strata on zen3-nixos (Qwen3.8-Flash-Next IQ3_XXS)

Status: **live** (2026-10-04). Strata (`github.com/Niko1221/Strata`) is the
engine that runs the 76 GB GSQ-RCO IQ3_XXS model on the 32 GiB R9700 that
llama.cpp could only do at ~6.5 tok/s. It replaces llama-swap on this box
(see "Why llama-swap is off" below). This doc records the install (which is
half hand-prepared outside Nix), the config, and the measured context /
memory ceilings that were the point of the exercise.

Upstream pinned: **v0.1.39**, rev `6f32ec070f23ced9f50e704d854d775da52591ab`
(`hosts/zen3-nixos/ai/strata-package.nix`). It builds its own ggml from a
pinned llama.cpp (`3cf03257f219afbe7334045ff7c6a06ac68c627d`).

## Why llama-swap is off

Both want the R9700's VRAM and tens of GB of RAM, and Strata exists to run a
model that does not fit. `hosts/zen3-nixos/ai/default.nix` imports
`./strata.nix` and leaves `./llama-swap.nix` commented out. Re-enable the
llama-swap import *and* drop the strata one together to go back; the two must
never be imported at once.

## What is where

| Piece | Path |
| --- | --- |
| GGUFs (2 shards, 75.8 GB) | `/home/cjdell/Models/Qwen3.8-Flash-Next-GSQ-RCO-GGUF/` |
| pack (index + dense + tokenizer) | `/home/cjdell/Strata/pack/iq3xxs/` (~1.5 GB) |
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
$PY iq_pack.py --gguf <ggufDir>/...-00001-of-00002.gguf --out /home/cjdell/Strata/pack/iq3xxs

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
