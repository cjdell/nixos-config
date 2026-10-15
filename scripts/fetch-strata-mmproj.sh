#!/usr/bin/env bash
# Fetch ISTA's Qwen3.8-Flash-Next vision encoder (zen3-nixos).
#
# `mmproj-Qwen3.8-Flash-Next-BF16.gguf` is the image ENCODER (a 27-layer ViT +
# the projector into the language model, 0.85 GiB) that turns a picture into
# rows of the model's embedding width. Strata's multimodal path needs it: the
# `vision` section of the run config (hosts/zen3-nixos/ai/strata.nix) names it,
# `strata-vision` (llama.cpp's mtmd) reads it, and the engine splices the rows
# in at the prompt's <|image_pad|> tokens.
#
# It is the SAME file for every Flash-Next family — setup.py's FAMILIES points
# the qwen, coder, unsloth and nvfp4 entries all at this repository
# (setup.py:388/403/413/422) — so switching config.ai.strataModel never needs a
# second download.
#
# Pinned by revision and checked against upstream's size + SHA-256
# (setup.py:67 HF_REVISIONS, setup.py:423 mmproj_sha256, and the identical
# metal/setup_mac.py:320 VISION_SHA256), so a moved HEAD or a truncated
# download cannot pass as a model file.
#
# Model data, so it goes beside the GGUFs in ~/Models and NOT into the store —
# same rule as the shards, the pack and the MTP runtime.
#
# Usage:
#   scripts/fetch-strata-mmproj.sh            # fetch + verify
#   scripts/fetch-strata-mmproj.sh --check    # verify what is on disk, no network
set -euo pipefail

REV=ed59f92082b1e93c0e96d60a8b11aab089b52f09      # setup.py HF_REVISIONS, 2026-09-29
BASE="https://huggingface.co/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF/resolve/$REV"
OUT=/home/cjdell/Models

FILE=mmproj-Qwen3.8-Flash-Next-BF16.gguf
BYTES=907543008
SHA=b1a82259702816a5330d7bd7607cd9676b11780e79ff7348c21103ff3ce49bd0

verify() { # -> 0 ok, 1 mismatch
  [ -f "$OUT/$FILE" ] && [ "$(stat -c %s "$OUT/$FILE")" -eq "$BYTES" ] || return 1
  echo "  verifying sha256 of $FILE ($(numfmt --to=iec "$BYTES")) ..."
  echo "$SHA  $OUT/$FILE" | sha256sum -c -
}

if [ "${1:-}" = "--check" ]; then
  verify && echo "ok: $OUT/$FILE"
  exit $?
fi

mkdir -p "$OUT"
if verify; then
  echo "already there: $OUT/$FILE"
  exit 0
fi

# 0.85 GiB on a /home that also holds 94 GB of model shards: refuse early
# rather than fail mid-download.
free_kb=$(df --output=avail -k "$OUT" | tail -1 | tr -d ' ')
[ "$free_kb" -gt $((1024 * 1024)) ] || { echo "less than 1 GiB free in $OUT" >&2; exit 1; }

echo "downloading $FILE ..."
wget -c --tries=5 --timeout=60 -O "$OUT/$FILE.part" "$BASE/$FILE"
mv "$OUT/$FILE.part" "$OUT/$FILE"
verify && echo "ok: $OUT/$FILE"
