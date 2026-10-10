#!/usr/bin/env bash
# Pack Unsloth's Qwen3.8-Flash-Next UD-IQ4_XS shards into a Strata pack
# (zen3-nixos).  Counterpart of scripts/repack-strata-iq3s.sh for the other
# family: it wraps tools/iq_pack.py with the engine's own python (numpy) and the
# pinned llama.cpp gguf-py, exactly as setup.py:5314 does for the "unsloth"
# family (setup.py:299 pack_args).
#
# Two things differ from the IQ3_S pack:
#   * --compat-bf16 is REQUIRED.  The UD file stores 195 hyper-connection /
#     dense projections as Q8_0, which the engine cannot read natively yet on
#     AMD; --compat-bf16 rounds them to BF16 in the pack (docs/UNSLOTH_Q4.md
#     "Why --compat-bf16").  Without it the pack will not load.
#   * NO --experts-bin.  That writes one ~60 GB arena file for the low-RAM
#     modes (--mmap-experts / --resident-experts); we keep the experts read
#     straight from the GGUF and put them in RAM with --resident-budget-gib
#     (hosts/zen3-nixos/ai/strata.nix), so the extra 60 GB has nowhere to go.
#
# iq_pack.py reads every shard beside --gguf (the UD shards are three separate
# GGUF containers: shard 1 is metadata only, 0 tensors; shard 2 carries 373
# tensors incl. the 26.82 GiB per_layer_token_embd table; shard 3 the rest), so
# all three must be complete: scripts/fetch-strata-udiq4xs.sh.
#
# Usage:
#   scripts/repack-strata-udiq4xs.sh --check   # verify the three shards, no pack
#   scripts/repack-strata-udiq4xs.sh           # run iq_pack.py into $OUT
set -euo pipefail

FLAKE=/home/cjdell/nixos-config
GGUF_DIR=/home/cjdell/Models/Qwen3.8-Flash-Next-UD-IQ4_XS-GGUF
OUT=/home/cjdell/Strata/pack/ud-iq4-xs
SHARD1=$GGUF_DIR/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf
# The llama.cpp rev the strata package pins (strata-package.nix, setup.py:166
# LLAMA_CPP_COMMIT) - same as scripts/repack-strata-iq3s.sh.
LLAMA_REV=3cf03257f219afbe7334045ff7c6a06ac68c627d
LLAMA_HASH=sha256-SRGoXa+4ACBCB3eaG9XFYhMN1i0FyPEy9Rrer+dFGYI=

# Size + SHA-256 of every shard (setup.py UNSLOTH_IQ4_XS_SHARDS): a pack built
# from a truncated or moved file is worse than no pack.
"$FLAKE/scripts/fetch-strata-udiq4xs.sh" --check || exit 1

if [ "${1:-}" = "--check" ]; then echo "UD-IQ4_XS shards OK"; exit 0; fi

STRATA=$(nix build --no-link --print-out-paths "$FLAKE#strata")
# The engine's own python has numpy but NOT pyyaml, and 0.1.41/0.1.42's iq_pack.py
# imports `from gguf import ...`, whose package __init__ pulls gguf/metadata.py
# -> `import yaml` (ModuleNotFoundError).  Use a python from the flake's nixpkgs
# pin with both.
PY=$(nix build --no-link --print-out-paths --impure --expr \
  "let f = builtins.getFlake \"$FLAKE\"; p = f.inputs.nixpkgs.legacyPackages.x86_64-linux; in \
   p.python3.withPackages (ps: [ ps.numpy ps.pyyaml ps.regex ])")/bin/python3
GGUF_PY=$(nix build --no-link --print-out-paths --impure --expr \
  "let f = builtins.getFlake \"$FLAKE\"; p = f.inputs.nixpkgs.legacyPackages.x86_64-linux; in \
   p.fetchFromGitHub { owner=\"ggml-org\"; repo=\"llama.cpp\"; \
     rev=\"$LLAMA_REV\"; hash=\"$LLAMA_HASH\"; }")/gguf-py
export STRATA_GGUF_PY=$GGUF_PY

echo "engine python: $PY"
echo "gguf-py:       $GGUF_PY"
echo "pack out:      $OUT"
mkdir -p "$OUT"
cd "$STRATA/share/strata/tools"
# ~1.5 GB of index + dense tensors + tokenizer; the experts stay in the GGUF.
exec "$PY" iq_pack.py --gguf "$SHARD1" --out "$OUT" --compat-bf16
