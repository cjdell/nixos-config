#!/usr/bin/env bash
# Fetch Unsloth's Qwen3.8-Flash-Next UD-IQ4_XS shards (zen3-nixos).
#
# 93.7 GB in three shards, from the Hugging Face revision the Strata 0.1.41 setup
# pins (setup.py:70 HF_REVISIONS["unsloth/Qwen3.8-Flash-Next-GGUF"]), with the
# sizes and SHA-256 of setup.py's UNSLOTH_IQ4_XS_SHARDS (docs/UNSLOTH_Q4.md
# "UD-IQ4_XS").  Pinned revision + sha256: a moved HEAD or a truncated download
# cannot pass as a model file.
#
# Idempotent: a shard already present at the right size and hash is skipped, so
# re-running resumes (wget -c) and re-verifies.  Nothing here deletes or replaces
# the IQ3_S shards - scripts/repack-strata-udiq4xs.sh packs from this directory.
#
# Usage:
#   scripts/fetch-strata-udiq4xs.sh            # fetch + verify all three shards
#   scripts/fetch-strata-udiq4xs.sh --check    # verify what is on disk, no network
set -euo pipefail

REV=38bb39ee97821de2c9009abb7e93950eec396e66
BASE="https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/$REV/UD-IQ4_XS"
OUT=/home/cjdell/Models/Qwen3.8-Flash-Next-UD-IQ4_XS-GGUF

# name -> "bytes sha256"  (setup.py UNSLOTH_IQ4_XS_SHARDS)
declare -A SHARDS=(
  [Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf]="10946624 5ce89370720f8bf90890f439361282104c1aa1482d4013bb9a50923e758e71a4"
  [Qwen3.8-Flash-Next-UD-IQ4_XS-00002-of-00003.gguf]="49835229856 577a38a2392b40ca2193cea502e1d92f60b8cd370675d308e0ec21885d9daaa7"
  [Qwen3.8-Flash-Next-UD-IQ4_XS-00003-of-00003.gguf]="43836407744 d4634e6d84f0ebb0940be15c90d3790bf6464e3dea3a1cddc567dc0e83ad8833"
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
  # 93.7 GB of new model on a box whose /home also holds the IQ3_S shards and the
  # engine's page/file tiers: refuse rather than fill the filesystem mid-download.
  free_kb=$(df --output=avail -k "$OUT" | tail -1 | tr -d ' ')
  [ "$free_kb" -gt $((96 * 1024 * 1024)) ] || {
    echo "only $((free_kb / 1024 / 1024)) GiB free on $OUT; the download is 93.7 GB." >&2
    echo "Reclaim first (llama-swap is off, so these are dead weight): Laguna-S-2.1-UD-IQ4_NL" \
         "(55 GB), Qwen3.8-27B-* (37 GB), Qwen3.6-35B-A3B (17 GB)." >&2
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
  echo "all three shards present and verified in $OUT"
  echo "next: scripts/repack-strata-udiq4xs.sh --check"
fi
exit "$rc"
