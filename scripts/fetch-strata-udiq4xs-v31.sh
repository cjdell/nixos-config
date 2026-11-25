#!/usr/bin/env bash
# Fetch Unsloth's Qwen3.8-Flash-Next UD-IQ4_XS "Dynamic v3.1" shards
# (zen3-nixos).
#
# 93.7 GB in FOUR shards, from the Hugging Face revision the Strata 0.2.11
# setup pins for the v31 re-upload (setup.py:432 UNSLOTH_V31_REVISION =
# "d9620119...", "Dynamic v3.1", 2026-11-04), with the sizes and SHA-256 of
# setup.py's UNSLOTH_V31_IQ4_XS_SHARDS.  Pinned revision + sha256: a moved HEAD
# or a truncated download cannot pass as a model file.
#
# This is NOT the three-shard UD-IQ4_XS set that scripts/fetch-strata-udiq4xs.sh
# downloads (revision 38bb39ee..., 2026-10).  Unsloth re-cut the quant for
# "Dynamic v3.1": 345 of 1224 tensors changed type and 33 expert layers moved to
# Q5_0 (Strata's fingerprint "unsloth/UD-IQ4_XS-v31", data/gguf_fingerprints.
# json; the 0.2.11 setup.py comment: only UD-IQ4_XS itself changed shape vs the
# old files).  Separate directory, separate pack, separate fetch script -
# nothing here touches the old set.
#
# Idempotent: a shard already present at the right size and hash is skipped, so
# re-running resumes (wget -c) and re-verifies.  Nothing here deletes or
# replaces anything; scripts/repack-strata-udiq4xs-v31.sh packs from this
# directory.
#
# Usage:
#   scripts/fetch-strata-udiq4xs-v31.sh            # fetch + verify all four shards
#   scripts/fetch-strata-udiq4xs-v31.sh --check    # verify what is on disk, no network
set -euo pipefail

REV=d96201194f103c906994f283f504209dc8d2a10c
BASE="https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/$REV/UD-IQ4_XS"
OUT=/home/cjdell/Models/Qwen3.8-Flash-Next-UD-IQ4_XS-v31-GGUF

# name bytes sha256  (setup.py:659-666 UNSLOTH_V31_IQ4_XS_SHARDS)
MANIFEST=$(cat <<'MANIFEST'
Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00004.gguf 10946618 93ff23a08e5cd7501f24fa16f5b415d5807d0175e04edd3ed6a7a41b601a4eef
Qwen3.8-Flash-Next-UD-IQ4_XS-00002-of-00004.gguf 49604491008 13d5dc8b93d039e4cfade5a9af7037f10c97f7ec4e53f75bd2e9ae34aae54aeb
Qwen3.8-Flash-Next-UD-IQ4_XS-00003-of-00004.gguf 15256783680 f6b9b5934908a2043732269dd740155d0f921d0763a1dcdd3452246311651f87
Qwen3.8-Flash-Next-UD-IQ4_XS-00004-of-00004.gguf 28800138432 5de8b5dbf89409acc39468decafd4a4a95b13c29d88a14b0356107897829ec36
MANIFEST
)

check_only=0
[ "${1:-}" = "--check" ] && check_only=1

# shellcheck source=scripts/lib/fetch-files.sh
source "$(dirname "$0")/lib/fetch-files.sh"

# 93.7 GB (87.3 GiB) of new model plus the ~1.5 GB pack.  The old guard
# wanted 96 GiB; with the Avalon set deleted this box has ~117 GiB and the
# old UD-IQ4_XS GGUFs still on disk, so the same bar applies - reclamation
# (the old set's GGUFs once the v31 pack is live) is a later decision.
fetch_files "$OUT" "$BASE" "$check_only" 96 "$MANIFEST"
rc=$?

if [ "$rc" -eq 0 ]; then
  echo "all four shards present and verified in $OUT"
  echo "next: scripts/repack-strata-udiq4xs-v31.sh --check"
fi
exit "$rc"
