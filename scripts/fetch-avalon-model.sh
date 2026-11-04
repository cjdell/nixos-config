#!/usr/bin/env bash
# Fetch the Avalon model set for Qwen3.8-Flash-Next (zen3-nixos).
#
# ~89.7 GiB from https://huggingface.co/freriadoc/Qwen3.8-Flash-Next-Avalon-GGUF
# pinned at revision 372fe3a4e572c5ba75a90e579de0695633d083a8 (2026-11-04) with
# the size + SHA-256 (the LFS oid from the HF tree API, same values install.sh
# verifies against): the 33 IQ3_KS-hybrid shards, the shared MTP draft head,
# and moe-cache-ranking.bin (the expert pre-ranking the GPU cache is prefilled
# from at load). Pinned revision + sha256: a moved HEAD or a truncated download
# cannot pass as a model file. This is the fetch equivalent of what
# install.sh's model step does, without the venv and without the git clone -
# the ENGINE comes from nix (nix build .#avalon), only the data lives here.
#
# The files land exactly where hosts/zen3-nixos/ai/avalon.nix expects them
# (modelDir), and the unit's ConditionPathExists stays false until they are all
# complete at the right hash, so partial state = avalon.service inert, strata
# (if re-enabled) unaffected.
#
# Idempotent: every file already present at the right size AND hash is skipped;
# a partial file resumes (curl -C -) and is verified afterwards.
#
# Usage:
#   scripts/fetch-avalon-model.sh            # fetch + verify everything
#   scripts/fetch-avalon-model.sh --check    # verify what is on disk, no network
set -euo pipefail

REV=372fe3a4e572c5ba75a90e579de0695633d083a8
BASE="https://huggingface.co/freriadoc/Qwen3.8-Flash-Next-Avalon-GGUF/resolve/$REV"
OUT=/home/cjdell/Models/Qwen3.8-Flash-Next-Avalon-GGUF

# path bytes sha256  (HF tree API @ $REV, lfs oid; install.sh's exclusion rules:
# no .md/.jpg; .gitattributes/LICENSE are cosmetic and NOT needed at runtime)
MANIFEST=$(cat <<'EOF'
Qwen3.8-Flash-Next-Avalon-IQ3KS-00001-of-00033.gguf 693388160 d30dac62347b0427281ee0945e95660f183873e978445fc7eb1a24917562e5af
Qwen3.8-Flash-Next-Avalon-IQ3KS-00002-of-00033.gguf 38400184512 c752084d816448118081a0cb57c8ab20563baa0c9675cf996dcca00fdab106a8
Qwen3.8-Flash-Next-Avalon-IQ3KS-00003-of-00033.gguf 1959834208 481361f1f90aa133efe20115a55dce9450d7a4ff608da7b53420d1d6e67729be
Qwen3.8-Flash-Next-Avalon-IQ3KS-00004-of-00033.gguf 1905877888 812d5efa646c32b7cd2a652b67e5c8f9889b051668c11636b714f569aacbe6d5
Qwen3.8-Flash-Next-Avalon-IQ3KS-00005-of-00033.gguf 1111012160 7526527bd4c4c5aa609b5ea94fb0d934a7dd90322a070eb79364b1a0d4b5628c
Qwen3.8-Flash-Next-Avalon-IQ3KS-00006-of-00033.gguf 2170465728 bfd8e9629d90587ab666a9d915daf9fe08791fe0149f3ea25c5b589c2b61da86
Qwen3.8-Flash-Next-Avalon-IQ3KS-00007-of-00033.gguf 1188551424 ad6b497aca1eedf837d02e0c7f9099eaf9e025d449da0b114bf58ea0f06e6f8d
Qwen3.8-Flash-Next-Avalon-IQ3KS-00008-of-00033.gguf 2008170208 6932d4fe078752dc54f0c02a3b63aab446d108838576fd46685c47fbb8a6a82e
Qwen3.8-Flash-Next-Avalon-IQ3KS-00009-of-00033.gguf 1948396000 cbc811c03de6d1a043a4efe8aee7a3b6739ea65ccbdb3ec63c7ba6312851e087
Qwen3.8-Flash-Next-Avalon-IQ3KS-00010-of-00033.gguf 1174691616 366f7ad435a855fe6187b455e0f88620f58c7ef10e390f1c830240a526cd3a88
Qwen3.8-Flash-Next-Avalon-IQ3KS-00011-of-00033.gguf 1786100480 c813953a725d96e4c6c3eb399a41acc4bb16c8dac68d7444b5abf8da3fe7dc50
Qwen3.8-Flash-Next-Avalon-IQ3KS-00012-of-00033.gguf 2336862944 6467c9aa282e2d2af0d2da0026e5aa535b8baf249cd5809d23d71061920f8470
Qwen3.8-Flash-Next-Avalon-IQ3KS-00013-of-00033.gguf 1310512704 4f2259923f3076117619756d12d3797108e220628f748552b0b9085396e8c155
Qwen3.8-Flash-Next-Avalon-IQ3KS-00014-of-00033.gguf 2441460480 fb85d861ebb57bc9a9af2cdfa5e00ec777477695256af9bf06220ac06bd052d7
Qwen3.8-Flash-Next-Avalon-IQ3KS-00015-of-00033.gguf 2087073504 fea7c6970e4cab1e4ee9a08b7c7f2942cf86916676c56dd363b64d17c43c5773
Qwen3.8-Flash-Next-Avalon-IQ3KS-00016-of-00033.gguf 1127764544 d8447daadb2f5d5dd430af5c4a4a1604dd0815096a9118cc1f4eb37ff47d095e
Qwen3.8-Flash-Next-Avalon-IQ3KS-00017-of-00033.gguf 2266317792 8a1ca38ebafe6dde99feb88773cf9015754dc99e2c48ae7ebf08ed744ecb9a15
Qwen3.8-Flash-Next-Avalon-IQ3KS-00018-of-00033.gguf 2353966592 f5a952e6d6452fd42badb38d12a6ff3a5a8ad17ec77f7264b2f29a0adb30ff83
Qwen3.8-Flash-Next-Avalon-IQ3KS-00019-of-00033.gguf 1188551488 81d5b88d63db9ce13eaa1ec6bad8f1827a191f74f36bca6773516977219cd97b
Qwen3.8-Flash-Next-Avalon-IQ3KS-00020-of-00033.gguf 2466922240 cd708979f51bce109201154fcbd9a0c9d6f76b6b6a04c9ac30a5e5452739d01c
Qwen3.8-Flash-Next-Avalon-IQ3KS-00021-of-00033.gguf 2276076032 468bca4d02a24c44a577c01a93bca40d5f68ef6315af4ea55d4b131008d7ece4
Qwen3.8-Flash-Next-Avalon-IQ3KS-00022-of-00033.gguf 1318870816 443c0265a6a834b4394180604507f0ea12f32e054a9f52a724f7e93db9da6451
Qwen3.8-Flash-Next-Avalon-IQ3KS-00023-of-00033.gguf 2257959680 ae703a69f223fe4af2bbb4e95a8a79524d62c1cd063d9ce3ccd7a8136044b57d
Qwen3.8-Flash-Next-Avalon-IQ3KS-00024-of-00033.gguf 2376184544 32c9caccdf08d1cb039f80fd7ffe89c154be48404487b8f8a897959d681bb86e
Qwen3.8-Flash-Next-Avalon-IQ3KS-00025-of-00033.gguf 930403904 1582edcab209594aa7cbdbd2f1657be97deabfd1470d344d900cdcd2b8306d83
Qwen3.8-Flash-Next-Avalon-IQ3KS-00026-of-00033.gguf 2402138880 624b7a35583ebb96725bdcb9c68158d81b9d6ab56ddc50a02895f2058aaf497d
Qwen3.8-Flash-Next-Avalon-IQ3KS-00027-of-00033.gguf 2362324704 ea84103b496f0edbe0bb6a16c7c621c2cf343cf6058924c4aa1e95d6b0ed55fc
Qwen3.8-Flash-Next-Avalon-IQ3KS-00028-of-00033.gguf 1246833280 06e5bdf821b0992b537f466416ed7cf7e8f86530062a7046086c53cf2d51ae89
Qwen3.8-Flash-Next-Avalon-IQ3KS-00029-of-00033.gguf 1325736544 1a2156238acffcb40a6b4fc7ee56df48b7d90a9c1ebb40d39c88f78b081942f5
Qwen3.8-Flash-Next-Avalon-IQ3KS-00030-of-00033.gguf 2420606496 214fb1b5d7c52a30667abfe0d63f3cbe23af3140521d8ce010e33cdbaeca399e
Qwen3.8-Flash-Next-Avalon-IQ3KS-00031-of-00033.gguf 1286154880 e7001aa8bd2f90d808d63509d087e877bd01d42d70651ceeaaa2db2ee6907add
Qwen3.8-Flash-Next-Avalon-IQ3KS-00032-of-00033.gguf 1325736544 0cde7655acec939b696cbaa8e169846880ca21e661b4ab4cfa5ff85105a1fec1
Qwen3.8-Flash-Next-Avalon-IQ3KS-00033-of-00033.gguf 1391129888 eefb5e6fa9559cc7fa70224858521b822cb1f6bfe4836ea2d6416b56beca65f6
MTP/mtp-Qwen3.8-Flash-Next-shared-IQ3K-IQ4NL-FR65k.gguf 1484237088 54448c4b164005756d24d2adff168ae88d270c363637ab84b3e0c0f5c7ce057d
moe-cache-ranking.bin 177192 4d471bd0f73ea1515a5e3db694352ac584abb9497f5c0b7deb7d379c2c93ae90
EOF
)

check_only=0
[ "${1:-}" = "--check" ] && check_only=1

check_one() { # path bytes sha -> 0 ok, 1 mismatch
  local p=$1 bytes=$2 sha=$3
  [ -f "$p" ] && [ "$(stat -c %s "$p")" -eq "$bytes" ] || return 1
  echo "$sha  $p" | sha256sum -c --status - || return 1
  return 0
}

mkdir -p "$OUT/MTP"

if [ "$check_only" -eq 0 ]; then
  # 89.7 GiB into the same filesystem that holds every other model: refuse
  # rather than fill the filesystem mid-download (the strata fetch does the
  # same; the candidates it named are already gone as of this script's day one,
  # hence the shorter hint).
  free_kb=$(df --output=avail -k "$OUT" | tail -1 | tr -d ' ')
  [ "$free_kb" -gt $((100 * 1024 * 1024)) ] || {
    echo "only $((free_kb / 1024 / 1024)) GiB free on $OUT; the download is 89.7 GiB." >&2
    echo "Reclaim first: scripts/cleanup-strata-iq3xxs.sh, /home/cjdell/Downloads," >&2
    echo "or an old model in /home/cjdell/Models you no longer serve." >&2
    exit 1
  }
fi

rc=0
while read -r name bytes sha; do
  [ -n "${name:-}" ] || continue
  dest="$OUT/$name"
  if check_one "$dest" "$bytes" "$sha"; then
    echo "OK   $name (already complete)"
    continue
  fi
  if [ "$check_only" -eq 1 ]; then
    echo "FAIL $name (missing, wrong size, or hash mismatch)"
    rc=1
    continue
  fi
  echo "GET  $name ($(numfmt --to=iec "$bytes")) ..."
  # -C - resumes the part wget... curl left behind; a complete-but-corrupt
  # file is RESTARTED (a resume cannot repair middle-of-file damage, and the
  # sha256 below would just fail again), so delete before retrying.
  if [ -f "$dest" ] && [ "$(stat -c %s "$dest")" -gt "$bytes" ]; then
    echo "  (larger than expected - removing and starting over)"
    rm -f "$dest"
  fi
  curl -fL --retry 8 --retry-delay 5 -C - "$BASE/$name" -o "$dest"
  if check_one "$dest" "$bytes" "$sha"; then
    echo "OK   $name"
  else
    echo "FAIL $name (hash mismatch after download - remove the file and re-run)" >&2
    rc=1
  fi
done <<<"$MANIFEST"

if [ "$rc" -eq 0 ]; then
  echo "All files present and verified. avalon.service's ConditionPathExists is satisfied:"
  ls -la "$OUT" | head -5
  echo "next: nixos-rebuild switch --flake ~/nixos-config (hand the cutover to the human; it kills strata)"
else
  echo "Some files are missing or failed verification ($rc)." >&2
fi
exit $rc
