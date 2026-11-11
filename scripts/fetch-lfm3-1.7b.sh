#!/usr/bin/env bash
# Fetch LiquidAI's LFM3-1.7B Q4_K_M GGUF (zen3-nixos, for the RX 580 service).
#
# LFM3-1.7B is Liquid's small hybrid (ConvNeXtr stem + gated-conv short convs +
# a 24-layer transformer where only 11 layers keep KV — 5 more are sliding
# window), native 256K context, Apache-2.0. hosts/zen3-nixos/ai/lfm3.nix
# serves it on the RX 580 (console GPU) so the small/quick lane answers
# alongside Strata's Qwen3.8-Flash-Next on the R9700 — never on the R9700.
#
# The same quant the asus-i7-6700-nixos gpu-mode llm lease serves; the file
# is pinned by repo revision + upstream size + SHA-256 from the HF API, so a
# moved HEAD or a truncated download cannot pass as a model file.
#
# Model data, so it goes beside the GGUFs in ~/Models and NOT into the store.
#
# Usage:
#   scripts/fetch-lfm3-1.7b.sh            # fetch + verify
#   scripts/fetch-lfm3-1.7b.sh --check    # verify what is on disk, no network
set -euo pipefail

REV=cd0c74c575b5c416f3011b5b4c298077f26ca8c2      # LiquidAI/LFM3-1.7B-GGUF HEAD, 2026-11-11
BASE="https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF/resolve/$REV"
OUT=/home/cjdell/Models

FILE=LFM3-1.7B-Q4_K_M.gguf
BYTES=1099627808
SHA=3793e1e6e2266919d6e015287221b41100175a98eddaba92e111aed3b05c93c4

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

free_kb=$(df --output=avail -k "$OUT" | tail -1 | tr -d ' ')
[ "$free_kb" -gt $((2 * 1024 * 1024)) ] || { echo "less than 2 GiB free in $OUT" >&2; exit 1; }

echo "downloading $FILE ..."
wget -c --tries=5 --timeout=60 -O "$OUT/$FILE.part" "$BASE/$FILE"
mv "$OUT/$FILE.part" "$OUT/$FILE"
verify && echo "ok: $OUT/$FILE"
