#!/usr/bin/env bash
# Build the tokenizer pack for Qwen3.6-35B-A3B (zen3-nixos) — the ONLY
# preparation this family needs, and the counterpart of
# scripts/repack-strata-udiq4xs-v31.sh for the Flash-Next packs.
#
# The own-path engine reads the GGUF in place (experts and all — the engine
# places them on the card itself), so there is no iq_pack.py step, no
# --compat-bf16, no MTP layer fetch: just the tokenizer, which the GGUF
# carries as metadata (gpt2 byte-level BPE, 248,320 tokens, pre=qwen35, the
# Jinja chat template).  tools/strata_tokenizer.py extracts it into
# <out>/tokenizer/, exactly what setup.py's install_own_path step 6 runs:
#   run([python, ROOT/"tools/strata_tokenizer.py", "--gguf", gguf, "--out", pack],
#       env=..., STRATA_GGUF_PY=str(llama/"gguf-py"))
# and what strata.nix's models.qwen36-ud-q4-k-xl points `tokenizer` at
# (serve/server.py reads tokenizer/vocab.json from the pack dir).
#
# STRATA_GGUF_PY must be the gguf-py of the pinned llama.cpp rev: the engine's
# python has numpy but gguf-py's __init__ pulls pyyaml, so the pack python is
# the flake nixpkgs one with numpy+pyyaml+regex (same recipe as the Flash-Next
# repacks).  The 3cf03257 checkout's hash is what strata-package.nix fetched
# for tools/vision until v0.2.15 vendored it (third_party/strata-llama, same
# pin); strata_tokenizer only needs gguf-py, which the checkout carries.
#
# Usage:
#   scripts/repack-strata-qwen36-35b-a3b.sh --check  # verify the GGUF, no pack
#   scripts/repack-strata-qwen36-35b-a3b.sh          # extract the tokenizer pack
set -euo pipefail

FLAKE=/home/cjdell/nixos-config
GGUF_DIR=/home/cjdell/Models/Qwen3.6-35B-A3B-MTP-GGUF
OUT=/home/cjdell/Strata/pack/qwen36-ud-q4-k-xl
GGUF=$GGUF_DIR/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf
# The llama.cpp rev every Strata 0.2.x pins (setup.py LLAMA_CPP_COMMIT) for
# the gguf-py block layouts: the same rev + hash the Flash-Next repacks use.
LLAMA_REV=3cf03257f219afbe7334045ff7c6a06ac68c627d
LLAMA_HASH=sha256-SRGoXa+4ACBCB3eaG9XFYhMN1i0FyPEy9Rrer+dFGYI=

# Size + SHA-256 verified first (setup.py QWEN36_FILES): a tokenizer from a
# truncated file is a tokenizer for nothing.
"$FLAKE/scripts/fetch-strata-qwen36-35b-a3b.sh" --check || exit 1

if [ "${1:-}" = "--check" ]; then echo "Qwen3.6-35B-A3B files OK"; exit 0; fi

STRATA=$(nix build --no-link --print-out-paths "$FLAKE#strata")
PY=$(nix build --no-link --print-out-paths --impure --expr \
  "let f = builtins.getFlake \"$FLAKE\"; p = f.inputs.nixpkgs.legacyPackages.x86_64-linux; in \
   p.python3.withPackages (ps: [ ps.numpy ps.pyyaml ps.regex ])")/bin/python3
GGUF_PY=$(nix build --no-link --print-out-paths --impure --expr \
  "let f = builtins.getFlake \"$FLAKE\"; p = f.inputs.nixpkgs.legacyPackages.x86_64-linux; in \
   p.fetchFromGitHub { owner=\"ggml-org\"; repo=\"llama.cpp\"; \
     rev=\"$LLAMA_REV\"; hash=\"$LLAMA_HASH\"; }")/gguf-py
export STRATA_GGUF_PY=$GGUF_PY

echo "engine:        $STRATA"
echo "python:        $PY"
echo "gguf-py:       $GGUF_PY"
echo "tokenizer out: $OUT"
mkdir -p "$OUT"
# ~15 s: metadata read only — the 22.85 GB of weights are never touched.
"$PY" "$STRATA/share/strata/tools/strata_tokenizer.py" --gguf "$GGUF" --out "$OUT"
# The tool's own gate: decode(encode(s)) == s over a corpus hitting every
# byte-level-BPE boundary (emoji, combining marks, C0 controls).
exec "$PY" "$STRATA/share/strata/tools/strata_tokenizer.py" --gguf "$GGUF" --out "$OUT" --check
