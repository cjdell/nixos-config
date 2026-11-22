#!/usr/bin/env bash
# Fetch ISTA-DASLab's Qwen3.8-Flash-Next Coder (GSQ-RCO-Coder, IQ1_M) shards
# (zen3-nixos).
#
# 58.4 GB in TWO shards, from the Hugging Face revision the Strata setup pins
# (setup.py HF_REVISIONS: "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-Coder-GGUF"
# = 5348543e..., 2026-09-29), with the sizes and SHA-256 of setup.py's
# CODER_FILES (0.2.13 source:420). Pinned revision + sha256: a moved HEAD or a
# truncated download cannot pass as a model file.
#
# This is the expert-pruned CODER variant of Flash-Next: 256 of the 512
# experts per layer kept (the ones code, tools and vision use), stored like
# IQ3_S at 3.5 bpw — the "IQ1_M" in the file name is the whole file's average
# bpw, not a tensor type (repo card: "No individual weight is stored at 1.89
# bits"). Same base model, tokenizer and mmproj as the original GSQ-RCO set;
# shard 2 (the per_layer_token_embd table) is byte-identical to the original's
# — its pinned sha 316b46f3… is the very one hosts/zen3-nixos/ai/strata.nix
# names for the old IQ3_S shard 2.
#
# The picture reader is NOT fetched here: the Coder uses the original's
# mmproj-Qwen3.8-Flash-Next-BF16.gguf (setup.py's CODER_FILES names it, and
# FAMILY coder says "the original's file"), which scripts/fetch-strata-mmproj.sh
# already put in /home/cjdell/Models for the live pack.
#
# Idempotent: a shard already present at the right size and hash is skipped, so
# re-running resumes (wget -c) and re-verifies. Nothing here deletes or
# replaces anything; scripts/repack-strata-coder-iq1m.sh packs from this
# directory.
#
# Usage:
#   scripts/fetch-strata-coder-iq1m.sh            # fetch + verify both shards
#   scripts/fetch-strata-coder-iq1m.sh --check    # verify what is on disk, no network
set -euo pipefail

REV=5348543e0147355ac9cbcb031184a3546350988e
BASE="https://huggingface.co/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-Coder-GGUF/resolve/$REV/IQ1_M"
OUT=/home/cjdell/Models/Qwen3.8-Flash-Next-GSQ-RCO-Coder-GGUF

# name -> "bytes sha256"  (setup.py CODER_FILES, verified against the pinned
# revision's HF tree 2026-11-22)
declare -A SHARDS=(
  [Qwen3.8-Flash-Next-GSQ-RCO-IQ1_M-00001-of-00002.gguf]="29608446496 e11083ba855e7666b48ea3f2db6a9c3a20c18751a012cc24f948de91b7087fad"
  [Qwen3.8-Flash-Next-GSQ-RCO-IQ1_M-00002-of-00002.gguf]="28800138432 316b46f3a2dbd68c900f43136ab9449f9dcc3725dfd8c794847c204bc161e113"
)

check_one() { # path bytes sha -> 0 ok, 1 mismatch
  local p=$1 bytes=$2 sha=$3
  [ -f "$p" ] && [ "$(stat -c %s "$p")" -eq "$bytes" ] || return 1
  echo "  verifying sha256 of $(basename "$p") ($(numfmt --to=iec "$bytes")) ..."
  echo "$sha  $p" | sha256sum -c - || return 1
  return 0
}

mkdir -p "$OUT"
check_only=0
[ "${1:-}" = "--check" ] && check_only=1

if [ "$check_only" -eq 0 ]; then
  # 58.4 GB of shards plus the ~1.5 GB pack (the old IQ3_S set's GGUFs were
  # deleted when v31 went live, so nothing here reclaims space on the way).
  free_kb=$(df --output=avail -k "$OUT" | tail -1 | tr -d ' ')
  [ "$free_kb" -gt $((64 * 1024 * 1024)) ] || {
    echo "only $((free_kb / 1024 / 1024)) GiB free on $OUT; the download is 58.4 GB." >&2
    echo "Reclaim first: the legacy sets in ~/Models you no longer pack from." >&2
    exit 1
  }
fi

rc=0
for name in $(printf '%s\n' "${!SHARDS[@]}" | sort); do
  read -r bytes sha <<<"${SHARDS[$name]}"
  dest="$OUT/$name"
  if check_one "$dest" "$bytes" "$sha"; then
    echo "OK   $name (already complete)"
    continue
  fi
  if [ "$check_only" -eq 1 ]; then
    echo "MISS $name (absent, short, or hash mismatch)"
    rc=1
    continue
  fi
  echo "GET  $name <- $BASE/$name"
  wget -c --tries=20 --timeout=60 --progress=dot:giga -O "$dest" "$BASE/$name" || {
    echo "wget failed for $name (re-run to resume)" >&2; rc=1; continue
  }
  check_one "$dest" "$bytes" "$sha" || { echo "HASH MISMATCH $name - delete it and re-run" >&2; rc=1; }
done

if [ "$rc" -eq 0 ]; then
  echo "both shards present and verified in $OUT"
  echo "next: scripts/repack-strata-coder-iq1m.sh --check"
fi
exit "$rc"
