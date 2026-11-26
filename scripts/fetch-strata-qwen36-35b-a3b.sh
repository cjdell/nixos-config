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
# WHICH SIZE, and the two ways to answer it (full analysis:
# docs/qwen36-256k-vram.md; the arithmetic is own_path_fit.py):
#   * 131072 (128K) on this 31.86 GiB R9700: **UD-Q4_K_XL is the entry the
#     service runs** — weights 21.29 + fp32 KV 5.75 + state + ~3.2 of buffers
#     sits right at "every expert stays in VRAM", which is the regime the
#     ~180 tok/s figure belongs to.
#   * 262144 (256K): engine 0.1.6x+ narrowed the cache (`--kv fp32|fp16|fp8|
#     fp4`, upstream's bench: 11.56 / 6.06 / 3.35 / **1.65** GiB at 262,144),
#     so UD-Q4_K_XL fits fully resident at ~26.2 GiB with --kv fp4 and no
#     download is needed. That is the primary answer since 2026-11-25 and
#     hosts/zen3-nixos/ai/strata.nix's `qwen36-256k-fp8` / `-fp4` entries run
#     the 0.2.21 build (./strata-q36-package.nix) for exactly that.
#   * 262144 on the PINNED 0.1.59.1 engine, which has no --kv: the weights
#     alone must clear ~17.1 GiB, so a smaller quant is the only route. Those
#     sizes are pinned below (size + sha from the HF tree API at the same
#     revision 5bc3e238, cross-checked against setup.py's own pins for the two
#     files it does list) so a Q3/IQ3 file can be added to strata.nix's models
#     map later without a download-first-and-hope.
#
# Tokenizer pack and mmproj are SIZE-AGNOSTIC: the repack script only reads
# the GGUF to extract the tokenizer, and mmproj-F16.gguf is the same picture
# reader for every quant of the family. One extra GGUF = one extra line in
# FILES + one models entry (whose `model_name` MUST be
# "qwen3.6-35b-a3b-<size lower-case>" — own_path_fit.from_model_name parses
# the size back out of it; a suffix beyond the size makes serve's context gate
# go deliberately silent, which is what the 256K entries want).
#
# Idempotent: a file already present at the right size and hash is skipped, so
# re-running resumes (wget -c) and re-verifies.  Nothing here deletes or
# replaces anything; scripts/repack-strata-qwen36-35b-a3b.sh builds the
# tokenizer pack from this directory.
#
# Usage:
#   scripts/fetch-strata-qwen36-35b-a3b.sh                 # the live set (Q4_K_XL + mmproj)
#   scripts/fetch-strata-qwen36-35b-a3b.sh --size UD-IQ3_XXS   # ...plus one smaller quant
#   scripts/fetch-strata-qwen36-35b-a3b.sh --list          # what is pinned, with fit notes
#   scripts/fetch-strata-qwen36-35b-a3b.sh --check         # verify what is on disk, no network
set -euo pipefail

REV=5bc3e238d916f48a861bac2f8a1990a0e9b7e98d
BASE="https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF/resolve/$REV"
OUT=/home/cjdell/Models/Qwen3.6-35B-A3B-MTP-GGUF

# name -> "bytes sha256"  (first block: setup.py QWEN36_FILES; the rest: the
# HF LFS oids at the SAME revision, which reproduce those two hashes exactly,
# so they are the same kind of pin)
declare -A FILES=(
  [Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf]="22853663008 55983c5a75a1ab969824077b3bb3de4146e82a9234072b48ad4e8f92ad3fe9f1"
  [mmproj-F16.gguf]="899283584 71f3cbc1f7cc0f30d09d41cfa924c0060827ebc33bf15ace7e86661e856f0160"
  # Q6_K_XL / Q8_0 are upstream-pinned too but exceed this card by themselves
  # at any context: [Qwen3.6-35B-A3B-UD-Q6_K_XL.gguf]="32611711264 35fce994cd36104a7dc1bd8a4bdf13778145664c00fdef6773aebc9246e5019c"
  # [Qwen3.6-35B-A3B-Q8_0.gguf]="37801097504 c1283d8b80c3e38b2735ddbc9766d3b3126f44d6c484be419d4e101d09a76131"
)

# Sizes worth having for 262,144 WITHOUT --kv (i.e. on the pinned 0.1.59.1
# engine): weights + 11.48 GiB fp32 KV + 0.07 state + ~3.2 buffers vs 31.86.
# `--size <name>` adds one of these to the set to fetch.
declare -A EXTRA=(
  [UD-Q3_K_XL]="17227569440 3fba9ab57290b34726837521335bf9268397174f3dd662880e2d0c5264d17b81"
  [UD-IQ3_XXS]="14069266720 36f9ec0e4c775f6efd3a61c1ea76f0875128469c3d012e3d9e2495a90e7a7150"
  [UD-IQ3_S]="15346432288 ab639a7f330f96c47d3e6c2dd2d6445182e7b763e17e6048dc850a71bbc9f27f"
  [UD-IQ4_XS]="18209036576 df27a780435b7b45c2597536112ea3cb091f8544c3d0c3318d9f4258b31f7adf"
)

# name -> one-line fit note at 262,144, for --list
declare -A NOTE=(
  [UD-Q4_K_XL]="21.3 GiB — live file; 256K only with --kv fp8/fp4 (0.2.21 engine), 128K fully resident on 0.1.59.1"
  [UD-Q3_K_XL]="16.0 GiB — 256K with fp32 KV, ~0.3-1.1 GiB margin: razor-thin"
  [UD-IQ3_XXS]="13.1 GiB — 256K with fp32 KV, ~4 GiB spare: the comfortable answer on a pinned engine"
  [UD-IQ3_S]="14.3 GiB — 256K with fp32 KV, ~2.5-3 GiB spare, better than IQ3_XXS"
  [UD-IQ4_XS]="17.0 GiB — too big for 256K at fp32 KV; the best quality that fits 160K-ish"
)

list_sizes() {
  echo "pinned at HF revision $REV (unsloth/Qwen3.6-35B-A3B-MTP-GGUF)"
  for n in "${!EXTRA[@]}"; do
    printf '  %-11s %s\n' "$n" "${NOTE[$n]:-}"
  done
  printf '  %-11s %s\n' "UD-Q4_K_XL" "${NOTE[UD-Q4_K_XL]}"
  echo "shared, size-agnostic: mmproj-F16.gguf (899,283,584 B)"
}

# ---- args ----
extra_size=""
check_only=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) check_only=1 ;;
    --list) list_sizes; exit 0 ;;
    --size) extra_size="${2:-}"; shift ;;
    -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

if [ -n "$extra_size" ]; then
  key="Qwen3.6-35B-A3B-${extra_size}.gguf"
  [ -n "${EXTRA[$extra_size]:-}" ] || {
    echo "no pin for --size $extra_size; --size is one of: ${!EXTRA[*]}" >&2
    exit 2
  }
  FILES[$key]="${EXTRA[$extra_size]}"
fi

check_one() { # path bytes sha -> 0 ok, 1 mismatch
  local p=$1 bytes=$2 sha=$3
  [ -f "$p" ] && [ "$(stat -c %s "$p")" -eq "$bytes" ] || return 1
  echo "  verifying sha256 of $(basename "$p") ($(numfmt --to=iec "$bytes")) ..."
  echo "$sha  $p" | sha256sum -c - || return 1
  return 0
}

mkdir -p "$OUT"

if [ "$check_only" -eq 0 ]; then
  # Guard the download against the free space the SELECTED files need, plus
  # 2 GiB of slack: /home is the partition the 94 GB Flash-Next pack lives on,
  # and a full /home hurts the live lane (its logs and the pack dir are there).
  need_b=0
  for spec in "${FILES[@]}"; do need_b=$((need_b + ${spec% *})); done
  need_gib=$((need_b / 1024 / 1024 / 1024 + 2))
  free_kb=$(df --output=avail -k "$OUT" | tail -1 | tr -d ' ')
  [ "$free_kb" -gt $((need_gib * 1024 * 1024)) ] || {
    echo "only $((free_kb / 1024 / 1024)) GiB free on $OUT; this run needs ~${need_gib} GiB." >&2
    echo "Nothing is fetched and nothing is deleted. Free space, or drop the --size." >&2
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
  echo "GET  $name <- $BASE/$name (~$((bytes / 1024 / 1024 / 1024)) GiB, resumable)"
  wget -c --tries=20 --timeout=60 --progress=dot:giga -O "$dest" "$BASE/$name" || {
    echo "wget failed for $name (re-run to resume)" >&2; rc=1; continue
  }
  check_one "$dest" "$bytes" "$sha" || { echo "HASH MISMATCH $name - delete it and re-run" >&2; rc=1; }
done

if [ "$rc" -eq 0 ]; then
  echo "every selected file present and verified in $OUT"
  echo "next: scripts/repack-strata-qwen36-35b-a3b.sh --check   # tokenizer pack, size-agnostic"
fi
exit "$rc"
