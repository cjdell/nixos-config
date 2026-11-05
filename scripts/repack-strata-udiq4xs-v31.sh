#!/usr/bin/env bash
# Pack Unsloth's Qwen3.8-Flash-Next UD-IQ4_XS "Dynamic v3.1" shards into a
# Strata pack (zen3-nixos).  Counterpart of scripts/repack-strata-udiq4xs.sh
# for the v31 re-upload (the set Strata 0.2.11 ships support for), same engine
# recipe: tools/iq_pack.py with --compat-bf16, the flake-pinned python and the
# pinned llama.cpp gguf-py, exactly as setup.py's "unsloth" family pack_args
# (0.2.11 setup.py:723/9809) do it.
#
# Same two rules as the old UD-IQ4_XS pack:
#   * --compat-bf16 is REQUIRED.  The UD file stores its hyper-connection /
#     dense projections as Q8_0, which the engine cannot read natively on AMD;
#     --compat-bf16 rounds them to BF16 in the pack.  Without it the pack will
#     not load.
#   * NO --experts-bin.  That writes one giant arena file for the low-RAM
#     modes (--mmap-experts / --resident-experts); we keep the experts read
#     straight from the GGUF and put them in RAM with --resident-budget-gib
#     (hosts/zen3-nixos/ai/strata.nix), so the extra arena has nowhere to go.
#
# iq_pack.py reads every shard beside --gguf.  The v31 set is FOUR separate
# GGUF containers (shard 1 is metadata only; 2/3 carry the tensors; 4 is the
# 28.8 GB per_layer_token_embd table, which is in the packer's NOT_IN_PACK and
# stays in the GGUF), and a layer boundary can now fall INSIDE a shard - the
# packer writes its v4 per-role shard column and the 0.2.11 engine reads that
# (an older engine refuses instead of misreading).  Fingerprint:
# "unsloth/UD-IQ4_XS-v31" in data/gguf_fingerprints.json (1224 tensors, IQ4_XS
# 15.2 + IQ3_XXS 18.0 + IQ4_NL 6.1 + IQ2_S 1.6 + Q2_0 0.5 + Q5_0 19.0 GB of
# experts).
#
# Usage:
#   scripts/repack-strata-udiq4xs-v31.sh --check   # verify the four shards, no pack
#   scripts/repack-strata-udiq4xs-v31.sh           # run iq_pack.py into $OUT
set -euo pipefail

FLAKE=/home/cjdell/nixos-config
GGUF_DIR=/home/cjdell/Models/Qwen3.8-Flash-Next-UD-IQ4_XS-v31-GGUF
OUT=/home/cjdell/Strata/pack/ud-iq4-xs-v31
SHARD1=$GGUF_DIR/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00004.gguf
# The llama.cpp rev the strata package pins (strata-package.nix, setup.py's
# ggml pin) - same commit as the old udiq4xs repack: the 0.2.11 bump did NOT
# move it.
LLAMA_REV=3cf03257f219afbe7334045ff7c6a06ac68c627d
LLAMA_HASH=sha256-SRGoXa+4ACBCB3eaG9XFYhMN1i0FyPEy9Rrer+dFGYI=

# Size + SHA-256 of every shard (setup.py UNSLOTH_V31_IQ4_XS_SHARDS): a pack
# built from a truncated or moved file is worse than no pack.
"$FLAKE/scripts/fetch-strata-udiq4xs-v31.sh" --check || exit 1

if [ "${1:-}" = "--check" ]; then echo "UD-IQ4_XS v31 shards OK"; exit 0; fi

STRATA=$(nix build --no-link --print-out-paths "$FLAKE#strata")
# The engine's own python has numpy but NOT pyyaml, and iq_pack.py imports
# `from gguf import ...`, whose package __init__ pulls gguf/metadata.py ->
# `import yaml` (ModuleNotFoundError).  Use a python from the flake's nixpkgs
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
