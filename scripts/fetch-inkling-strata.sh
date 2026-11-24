#!/usr/bin/env bash
# Companion files for running Inkling-2-Mini ON STRATA (0.2.19+, lane
# hosts/zen3-nixos/ai/inkling.nix, package strata-inkling-package.nix).
#
# WHAT THIS IS vs scripts/fetch-inkling-2-mini.sh: that one fetches the
# llama.cpp lane's model file. The GGUF stays exactly where it is — Strata's
# strata-inkling engine reads it in place ("direct GGUF_RAW execution",
# 0.2.20; both Unsloth GGUF layouts accepted since 0.2.21, pins in
# strata_control/inkling_family.py). This script adds the four things
# strata-inkling needs that the llama.cpp lane never did:
#
#   tokenizer.json + chat_template.jinja   26 MB + 6.7 KB, from
#         strata-engine/Inkling-2-Mini-Strata. The serve layer builds its
#         chat dialect from these (strata_cli/launch/adopt.py's
#         _ensure_inkling_tokenizer; the unit's ExecStartPre runs
#         tools/inkling_tokenizer.py on them once).
#   Inkling-2-Mini-Vision.strata           0.64 GB lossless BF16 vision shard.
#         strata-inkling reads images from THIS and only this: the mmproj-*.gguf
#         beside the Unsloth GGUF is llama.cpp's projector, which the engine
#         explicitly does not read (adopt.py's note). Without it: text-only.
#   mtp.safetensors                        636 MB, the DSpark drafter from
#         THINKING MACHINES' own repo (commit 1fb4134b, Apache, ungated). The
#         0.1.6x engines that list `dspark_f32_widen=1` in `--info` draft
#         3-7x per step from it (the BF16 file needs their F32 widen; older
#         engines get 1.0 and are served the Q8_0 file below instead —
#         serve/inkling_kind.py's fit_dspark() swaps automatically).
#   dspark-Inkling-2-Mini-Q8_0.gguf        402 MB, Unsloth's Q8_0 drafter at
#         the PINNED pre-re-upload commit 800c946d (the 2026-11-23 re-upload
#         of this file is a dflash layout the engine cannot read —
#         inkling_family.py drops it with a message, so fetch this commit,
#         not main).
#
# --sq20 / --sq10 (opt-in) fetch Strata's native .strata v1.1 packs:
#   SQ-20 (19.35 GB)  bit-exact lossless SF4+MX8 vs the original (0.00000 KL,
#                     100% top-1) — the quality pick for this 32 GiB card.
#   SQ-10 (10.47 GB)  what upstream's own R9700 speed table was measured with;
#                     +0.32 WikiText-2 ppl — measure before believing.
# The GGUF path needs NO extra download (file already on disk); SQ packs
# replace --native and drop the GGUF drafter files (the .strata builds want
# mtp.safetensors, which this script also fetches).
#
# Pins are the exact (bytes, sha256) tables in Strata's
# terminal/strata_control/inkling_family.py (v0.2.21) + the HF LFS oids.
# Idempotent, resumable (wget -c), re-verified; --check verifies only.
#
# Usage:
#   scripts/fetch-inkling-strata.sh              # the four strata-side files
#   scripts/fetch-inkling-strata.sh --sq20       # ... plus SQ-20 (19.35 GB)
#   scripts/fetch-inkling-strata.sh --sq10       # ... plus SQ-10 (10.47 GB)
#   scripts/fetch-inkling-strata.sh --check      # verify on disk, no network
set -euo pipefail

OUT=/home/cjdell/Models/Inkling-2-Mini-GGUF
PACK_BASE="https://huggingface.co/strata-engine/Inkling-2-Mini-Strata/resolve/main"
UNSLOTH_BASE="https://huggingface.co/unsloth/Inkling-2-Mini-GGUF/resolve/800c946d7b9c830c86290df49afbbe91db8455f5"
TM_BASE="https://huggingface.co/thinkingmachines/Inkling-2-Mini/resolve/1fb4134b9a74f9681054f4ef82e4bf1f458a2337"

# dest name -> "bytes sha256|none url"
FILES=(
  "tokenizer.json|26178678|7f332727f9a3f093dd452a39cc978e6757627e5dad1b0673aa4e75174f236dd6|$PACK_BASE/tokenizer.json"
  "chat_template.jinja|6868|none|$PACK_BASE/chat_template.jinja"
  "Inkling-2-Mini-Vision.strata|636526592|6589eff47f9c20bc3a032faa3d449f10bf4f04a84cc6b2ee8a44d51d2b6fc677|$PACK_BASE/Inkling-2-Mini-Vision.strata"
  "mtp.safetensors|635801416|7c3b651317f01f73bcf4e1dceba66ef8b7e1a1eac6bc171e882e690a4b10a1d2|$TM_BASE/mtp.safetensors"
  "dspark-Inkling-2-Mini-Q8_0.gguf|402278560|2ec78510da837e8fc3be54a14757a0c5fbd2d8d9e85a0d92853fafdf674f3773|$UNSLOTH_BASE/dspark-Inkling-2-Mini-Q8_0.gguf"
)
EXTRA=()
CHECK=0
for a in "$@"; do
  case "$a" in
    --check) CHECK=1 ;;
    --sq20) EXTRA+=("Inkling-2-Mini-SQ-20.strata|19346685952|0bbfd52344f0dd4779a7807b5f73554a812f24c035e6877b63cd0d499f7e1b97|$PACK_BASE/Inkling-2-Mini-SQ-20.strata") ;;
    --sq10) EXTRA+=("Inkling-2-Mini-SQ-10.strata|10471526400|ac4d452ad03e4930abd9d46f9c5eec22b2f75a1da45a1e49bd24ccd58b065934|$PACK_BASE/Inkling-2-Mini-SQ-10.strata") ;;
    *) echo "unknown option: $a (want --sq20, --sq10, --check)" >&2; exit 2 ;;
  esac
done
FILES+=("${EXTRA[@]}")

verify() { # path bytes sha
  local p=$1 want=$2 sha=$3 have sz
  sz=$(stat -c %s "$p" 2>/dev/null || echo 0)
  [ "$sz" = "$want" ] || { echo "  size $sz != $want"; return 1; }
  [ "$sha" = none ] && return 0
  have=$(sha256sum "$p" | cut -d' ' -f1)
  [ "$have" = "$sha" ] || { echo "  sha256 $have != $sha"; return 1; }
  return 0
}

mkdir -p "$OUT"
rc=0
for spec in "${FILES[@]}"; do
  IFS='|' read -r name bytes sha url <<<"$spec"
  p="$OUT/$name"
  if verify "$p" "$bytes" "$sha" 2>/dev/null; then
    echo "ok      $name ($bytes B)"
    continue
  fi
  if [ "$CHECK" = 1 ]; then
    echo "MISSING $name (expected $bytes B)" >&2
    rc=1
    continue
  fi
  echo "fetch   $name <- $url"
  wget -c -q --show-progress -O "$p.part" "$url"
  # a resumed .part may predate a pin change; verify, then move.
  mv "$p.part" "$p"
  if verify "$p" "$bytes" "$sha"; then
    echo "ok      $name ($bytes B)"
  else
    echo "FAILED  $name: size/sha mismatch (left in place for inspection)" >&2
    rc=1
  fi
done
exit $rc
