#!/usr/bin/env bash
# Fetch Thinking Machines' Inkling-2-Mini for the llama.cpp swap lane on
# zen3-nixos (hosts/zen3-nixos/ai/inkling.nix, served behind strata-swap on
# :8080 as "inkling-2-mini-ud-q4_k_xl").
#
# WHAT, and why these exact files: the repo's ROOT UD GGUFs use Unsloth's
# looped tensor layout and need Unsloth's own llama.cpp build. Mainline
# llama.cpp (this flake's `llama-cpp` input) reads the `inkling2_loop` layout
# instead, which lives in Mainline_Support/ as `.gguf_file` — same tensors,
# only tensor names/metadata differ — and this script renames it to `.gguf`
# on download, exactly what Mainline_Support/README.md prescribes. The build
# must be >= b12611 (#32704, merged): older mainline silently loses the
# per-expert NVFP4 scales on loop passes 2/3 and outputs ~gibberish
# (ppl ~130 vs 7.65) — there is no load-time error, so the pin below plus the
# flake input floor are the guards.
#
# Quant choice (Unsloth's own KLD table for this repo): UD-Q4_K_XL is the
# plateau — mean KLD 0.0107 vs the Q8_K_XL reference (98.0% same top token),
# and 5.2 GB smaller, which is what makes the 512K ctx the service runs fit
# the 32 GiB R9700. Q8_K_XL (22.9 GB) + 512K KV does not fit the card.
#
# --iq4xs additionally fetches UD-IQ4_XS (15.7 GB, ~1.9 GB smaller): the same
# model with IQ4_XS experts instead of NVFP4. That matters on this GPU — RADV
# reports `fp4: 0` and ggml-vulkan disables the int8 coopmat MMQ for NVFP4 on
# RDNA4 (`if (!rdna4)` in ggml-vulkan.cpp), while IQ4_XS gets the fast prompt
# path. Optional, so a plain run does not spend 15.7 GB on it.
#
# mmproj-F16.gguf is the vision projector (root file, works on mainline —
# llama-server --mmproj per the same README).
#
# NOT fetched: the DSpark block drafter (`--spec-type draft-dspark`) —
# mainline support is still the open PR ggml-org/llama.cpp#32218; when that
# merges, add Mainline_Support/dspark-Inkling-2-Mini-Q8_0.gguf_file here and
# the flags to inkling.nix. `--mtp`/draft-mtp do NOT apply to this model.
#
# Idempotent: a file already present at the right size and hash is skipped, so
# re-running resumes (wget -c) and re-verifies. Pinned revision + sha256: a
# moved HEAD or a truncated download cannot pass as a model file.
#
# Usage:
#   scripts/fetch-inkling-2-mini.sh            # fetch + verify the run set
#   scripts/fetch-inkling-2-mini.sh --iq4xs    # ... plus UD-IQ4_XS (15.7 GB)
#   scripts/fetch-inkling-2-mini.sh --check    # verify what is on disk, no network
set -euo pipefail

REV=13bbdd720e18cf4e6be1d955f4db7b80446dde12
BASE="https://huggingface.co/unsloth/Inkling-2-Mini-GGUF/resolve/$REV"
OUT=/home/cjdell/Models/Inkling-2-Mini-GGUF

# dest name -> "bytes sha256 upstream-path"
# (sha256 = the LFS oid of the pinned revision's file, i.e. the real content hash)
declare -A FILES=(
  [Inkling-2-Mini-UD-Q4_K_XL.gguf]="17629760736 e64276656f072e9b2197a61723667cbdb71da66a716ffd966e572c21088f3cd3 Mainline_Support/Inkling-2-Mini-UD-Q4_K_XL.gguf_file"
  [mmproj-F16.gguf]="639348160 3bff75ffeb2d6e0371ba7bd42e30d26a7d98aea681fa44b03b5a20891cfa2c5f mmproj-F16.gguf"
)
# Fetched only with --iq4xs (see the quant note above).
declare -A OPTIONAL_FILES=(
  [Inkling-2-Mini-UD-IQ4_XS.gguf]="15733756512 374970bf6f151fc50da49419751c3e77b82e373a3b9445ded617bd386cd12163 Mainline_Support/Inkling-2-Mini-UD-IQ4_XS.gguf_file"
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
want_iq4xs=0
for arg in "$@"; do
  case "$arg" in
    --check) check_only=1 ;;
    --iq4xs) want_iq4xs=1 ;;
    *) echo "usage: $0 [--check] [--iq4xs]" >&2; exit 2 ;;
  esac
done

declare -A SEL
for k in "${!FILES[@]}"; do SEL[$k]=${FILES[$k]}; done
if [ "$want_iq4xs" -eq 1 ]; then
  for k in "${!OPTIONAL_FILES[@]}"; do SEL[$k]=${OPTIONAL_FILES[$k]}; done
fi

if [ "$check_only" -eq 0 ]; then
  # Guard on what is actually missing, + 2 GiB. This set lives ALONGSIDE the
  # live Flash-Next 94 GB pack (which stays), so check before pruning anything.
  need=0
  for name in "${!SEL[@]}"; do
    read -r bytes _ <<<"${SEL[$name]}"
    [ -f "$OUT/$name" ] && [ "$(stat -c %s "$OUT/$name")" -eq "$bytes" ] && continue
    need=$((need + bytes))
  done
  free_kb=$(df --output=avail -k "$OUT" | tail -1 | tr -d ' ')
  [ "$free_kb" -gt $(( (need / 1024) + 2 * 1024 * 1024 )) ] || {
    echo "only $((free_kb / 1024 / 1024)) GiB free on $OUT; still need $((need / 1024 / 1024 / 1024)) GiB" >&2
    exit 1
  }
fi

rc=0
for name in $(printf '%s\n' "${!SEL[@]}" | sort); do
  read -r bytes sha src <<<"${SEL[$name]}"
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
  echo "GET  $name <- $BASE/$src"
  wget -c --tries=20 --timeout=60 --progress=dot:giga -O "$dest" "$BASE/$src" || {
    echo "wget failed for $name (re-run to resume)" >&2; rc=1; continue
  }
  check_one "$dest" "$bytes" "$sha" || { echo "HASH MISMATCH $name - delete it and re-run" >&2; rc=1; }
done

if [ "$rc" -eq 0 ]; then
  echo "all requested files present and verified in $OUT"
  echo "next: confirm the llama-cpp input is >= b12611 (#32704 inkling2_loop) AND"
  echo "      >= #32735 (the Vulkan non-contiguous SCALE fix), then name"
  echo "      \"inkling-2-mini-ud-q4_k_xl\" in a request to :8080 to swap to it."
fi
exit "$rc"
