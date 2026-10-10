#!/usr/bin/env bash
# Repack the Qwen3.8-Flash-Next GSQ-RCO IQ3_S shards into a Strata pack
# (zen3-nixos).  Strata's model data is prepared outside Nix (see
# hosts/zen3-nixos/ai/strata.nix); this wraps tools/iq_pack.py with the
# engine's own python (numpy) and the pinned llama.cpp gguf-py it needs.
#
# IQ3_S is the highest GSQ-RCO quant (3.50 bpw); its shard 1 is 51.05 GiB vs
# IQ3_XXS's 43.81 GiB.  Shard 2 (the 26.82 GiB per_layer_token_embd table) is
# byte-identical across every GSQ-RCO quant and is hardlinked beside shard 1.
#
# Prereqs: both IQ3_S shards present in $GGUF_DIR (shard 1 fully downloaded).
#
# Usage:
#   scripts/repack-strata-iq3s.sh --check   # verify the shards exist and are full
#   scripts/repack-strata-iq3s.sh           # run iq_pack.py into $OUT
set -euo pipefail

FLAKE=/home/cjdell/nixos-config
GGUF_DIR=/home/cjdell/Models/Qwen3.8-Flash-Next-GSQ-RCO-GGUF
OUT=/home/cjdell/Strata/pack/iq3s
SHARD1=$GGUF_DIR/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-00001-of-00002.gguf
SHARD2=$GGUF_DIR/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-00002-of-00002.gguf
S1_SIZE=54817524224
S2_SIZE=28800138432
# The llama.cpp rev the strata package pins (strata-package.nix, STRATA_GGML_DIR).
LLAMA_REV=3cf03257f219afbe7334045ff7c6a06ac68c627d
LLAMA_HASH=sha256-SRGoXa+4ACBCB3eaG9XFYhMN1i0FyPEy9Rrer+dFGYI=

[ -f "$SHARD1" ] || { echo "missing shard 1: $SHARD1" >&2; exit 1; }
[ -f "$SHARD2" ] || { echo "missing shard 2: $SHARD2" >&2; exit 1; }
s1=$(stat -c %s "$SHARD1"); s2=$(stat -c %s "$SHARD2")
[ "$s1" -eq "$S1_SIZE" ] || { echo "shard 1 is $s1 bytes, expected $S1_SIZE (download incomplete?)" >&2; exit 1; }
[ "$s2" -eq "$S2_SIZE" ] || { echo "shard 2 is $s2 bytes, expected $S2_SIZE" >&2; exit 1; }

if [ "${1:-}" = "--check" ]; then echo "IQ3_S shards OK"; exit 0; fi

STRATA=$(nix build --no-link --print-out-paths "$FLAKE#strata")
# Not the engine's python: 0.1.41/0.1.42's iq_pack.py imports `from gguf import ...`,
# whose package __init__ needs pyyaml, which serverPython does not carry.  Same
# python scripts/repack-strata-udiq4xs.sh uses.
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
exec "$PY" iq_pack.py --gguf "$SHARD1" --out "$OUT"
