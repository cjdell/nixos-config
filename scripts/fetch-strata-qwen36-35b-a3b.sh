#!/usr/bin/env bash
# Fetch Unsloth's Qwen3.6-35B-A3B GGUF + picture reader for Strata's
# own-path engine (zen3-nixos) — the second served family behind
# config.ai.strataModel = "qwen36-ud-q4-k-xl" (hosts/zen3-nixos/ai/strata.nix).
#
# One GGUF (read in place by the engine — no pack, no shards) plus its
# mmproj-F16.gguf, from the Hugging Face revision Strata's own setup pins:
# setup.py HF_REVISIONS["unsloth/Qwen3.6-35B-A3B-MTP-GGUF"] = "5bc3e238..."
# (2026-10-12), sizes + SHA-256 from setup.py QWEN36_FILES (byte-identical
# pins on v0.2.13.1, main-13eedf55 and v0.2.15).  Pinned revision + sha256: a
# moved HEAD or a truncated download cannot pass as a model file.
#
# The family is Qwen3.6-35B-A3B ("35B a3b": 256 experts, 3B active, top-8,
# arch qwen35moe — the "35" in the file names and in src/qwen35/ is the arch,
# the catalog name is 3.6).  Unsloth's MTP-GGUF set carries the MTP block the
# engine drafts with, which is why the repo is the -MTP- one.
#
# Q6_K_XL (32,611,711,264 B, sha 35fce994cd36104a7dc1bd8a4bdf13778145664c00fdef6773aebc9246e5019c)
# and Q8_0 (37,801,097,504 B, sha c1283d8b80c3e38b2735ddbc9766d3b3126f44d6c484be419d4e101d09a76131)
# are the larger sizes of the same family, also pinned in QWEN36_FILES; the
# service entry exists for UD-Q4_K_XL (the 32 GB card holds every expert for
# one 128K session only at that size — own_path_fit.py), so this script
# fetches UD-Q4_K_XL + the shared mmproj.  A future size = a new entry in
# strata.nix's models map + one more line here.
#
# Idempotent: a file already present at the right size and hash is skipped, so
# re-running resumes (wget -c) and re-verifies.  Nothing here deletes or
# replaces anything; scripts/repack-strata-qwen36-35b-a3b.sh builds the
# tokenizer pack from this directory.
#
# Usage:
#   scripts/fetch-strata-qwen36-35b-a3b.sh            # fetch + verify both files
#   scripts/fetch-strata-qwen36-35b-a3b.sh --check    # verify what is on disk, no network
set -euo pipefail

REV=5bc3e238d916f48a861bac2f8a1990a0e9b7e98d
BASE="https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF/resolve/$REV"
OUT=/home/cjdell/Models/Qwen3.6-35B-A3B-MTP-GGUF

# name -> "bytes sha256"  (setup.py QWEN36_FILES)
declare -A FILES=(
  [Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf]="22853663008 55983c5a75a1ab969824077b3bb3de4146e82a9234072b48ad4e8f92ad3fe9f1"
  [mmproj-F16.gguf]="899283584 71f3cbc1f7cc0f30d09d41cfa924c0060827ebc33bf15ace7e86661e856f0160"
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
  # 23.75 GB of new model (Q4_K_XL + mmproj); guard at 26 GiB so a resumed
  # partial never fills /home mid-download.  The Flash-Next v31 set (94 GB)
  # STAYS — it is the live model; free space here came from the deleted
  # Avalon/IQ3_S/old-UD sets, not from touching it.
  free_kb=$(df --output=avail -k "$OUT" | tail -1 | tr -d ' ')
  [ "$free_kb" -gt $((26 * 1024 * 1024)) ] || {
    echo "only $((free_kb / 1024 / 1024)) GiB free on $OUT; the download is 23.8 GB." >&2
    exit 1
  }
fi

rc=0
for name in $(printf '%s\n' "${!FILES[@]}" | sort); do
  read -r bytes sha <<<"${FILES[$name]}"
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
  echo "both files present and verified in $OUT"
  echo "next: scripts/repack-strata-qwen36-35b-a3b.sh --check"
fi
exit "$rc"
