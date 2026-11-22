#!/usr/bin/env bash
# Pack ISTA-DASLab's Qwen3.8-Flash-Next Coder (GSQ-RCO-Coder, IQ1_M) shards
# into a Strata pack (zen3-nixos).  Counterpart of
# scripts/repack-strata-udiq4xs-v31.sh for the Coder release.
#
# The pack recipe is the ORIGINAL GSQ-RCO one — plain tools/iq_pack.py, and in
# particular NO --compat-bf16: that flag exists because the *Unsloth* files
# store their hyper-connection / dense projections as Q8_0, which the engine
# cannot read natively on AMD.  The Coder is an ISTA GSQ-RCO file (its retained
# experts are IQ3_S's 3.5 bpw; its dense/hc tensors are the original's BF16,
# which reads fine), and setup.py's family table carries "pack_args"
# [--compat-bf16] only on the unsloth/gyro families — the coder family has
# none.  This is the same command the header of hosts/zen3-nixos/ai/strata.nix
# used for the old IQ3_S pack.
#
# NO --experts-bin either (same rule as every pack here): the experts stay in
# the GGUF and the engine maps them into RAM — with a 23.4 GB arena (setup.py
# MODELS["IQ1_M"], no "budget" flag) all of them are resident on this box
# without --resident-budget-gib, which the pack would only duplicate.
#
# iq_pack.py reads every shard beside --gguf: shard 1 is the metadata +
# experts/dense, shard 2 the per_layer_token_embd table (in the packer's
# NOT_IN_PACK, stays in the GGUF; strata.nix passes it to the engine as
# --ple-gguf).  The pack carries index + dense tensors + TOKENIZER (~1.5 GB);
# the MTP draft runtime the live setup already has at /home/cjdell/Strata/mtp/rt
# serves the Coder too — pruning removed routed experts, never the draft head,
# and the GSQ-RCO files never shipped MTP tensors anyway (the runtime was
# packed from the BF16 original).  DFlash2 does NOT apply to the Coder
# (drafting.py SUPPORTED_FAMILIES = qwen/gyro/unsloth), so no drafter step.
#
# Expert ranking note: the engine is pointed at expert-profile-coder.bin (the
# shipped profile for this family, 12,288 pairs — half of the full model's,
# since half the experts are gone). That is strata.nix's job (models.coder-iq1m
# carries `profile`); nothing here touches it.
#
# Usage:
#   scripts/repack-strata-coder-iq1m.sh --check   # verify the two shards, no pack
#   scripts/repack-strata-coder-iq1m.sh           # run iq_pack.py into $OUT
set -euo pipefail

FLAKE=/home/cjdell/nixos-config
GGUF_DIR=/home/cjdell/Models/Qwen3.8-Flash-Next-GSQ-RCO-Coder-GGUF
OUT=/home/cjdell/Strata/pack/coder-iq1m
SHARD1=$GGUF_DIR/Qwen3.8-Flash-Next-GSQ-RCO-IQ1_M-00001-of-00002.gguf
# The llama.cpp rev the strata package pins (strata-package.nix, setup.py's
# ggml pin) — same as the v31 repack; the packer only needs gguf-py from it.
LLAMA_REV=3cf03257f219afbe7334045ff7c6a06ac68c627d
LLAMA_HASH=sha256-SRGoXa+4ACBCB3eaG9XFYhMN1i0FyPEy9Rrer+dFGYI=

# Size + SHA-256 of every shard (setup.py CODER_FILES): a pack built from a
# truncated or moved file is worse than no pack.
"$FLAKE/scripts/fetch-strata-coder-iq1m.sh" --check || exit 1

if [ "${1:-}" = "--check" ]; then echo "Coder IQ1_M shards OK"; exit 0; fi

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
# (No --compat-bf16 — see the header.)
exec "$PY" iq_pack.py --gguf "$SHARD1" --out "$OUT"
