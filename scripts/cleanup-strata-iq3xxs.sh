#!/usr/bin/env bash
# Remove the old Qwen3.8-Flash-Next IQ3_XXS model once IQ3_S is confirmed good.
#
# IQ3_XXS shard 2 is HARDLINKED to the IQ3_S shard 2 (they are byte-identical,
# LFS sha256 316b46f3...), so deleting the IQ3_XXS name frees nothing - only
# shard 1 and the old pack actually release space.  The reference is dropped so
# the directory looks clean.
#
# Safety: refuses to delete unless IQ3_S's pack and both shards exist AND the
# running strata engine is serving IQ3_S.  Default is a dry run.
#
# Usage:
#   scripts/cleanup-strata-iq3xxs.sh          # dry run (shows what would go)
#   scripts/cleanup-strata-iq3xxs.sh --yes     # actually delete
#   scripts/cleanup-strata-iq3xxs.sh --keep-pack   # leave the iq3xxs pack in place
set -euo pipefail

GGUF_DIR=/home/cjdell/Models/Qwen3.8-Flash-Next-GSQ-RCO-GGUF
PACK_I3S=/home/cjdell/Strata/pack/iq3s
PACK_OLD=/home/cjdell/Strata/pack/iq3xxs
S1_IQ3S=$GGUF_DIR/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-00001-of-00002.gguf
S2_IQ3S=$GGUF_DIR/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-00002-of-00002.gguf
S1_OLD=$GGUF_DIR/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-00001-of-00002.gguf
S2_OLD=$GGUF_DIR/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-00002-of-00002.gguf
S1SIZE=54817524224
S2SIZE=28800138432

yes=0; keep_pack=0
for a in "$@"; do
  case "$a" in
    --yes) yes=1 ;;
    --keep-pack) keep_pack=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

# --- preconditions: IQ3_S must be present and live ---
fail=0
[ -f "$S1_IQ3S" ] && [ "$(stat -c %s "$S1_IQ3S")" -eq "$S1SIZE" ] || { echo "FAIL: IQ3_S shard 1 missing/incomplete" >&2; fail=1; }
[ -f "$S2_IQ3S" ] && [ "$(stat -c %s "$S2_IQ3S")" -eq "$S2SIZE" ] || { echo "FAIL: IQ3_S shard 2 missing/incomplete" >&2; fail=1; }
[ -f "$PACK_I3S/index.txt" ] || { echo "FAIL: IQ3_S pack missing ($PACK_I3S/index.txt)" >&2; fail=1; }
live=$(timeout 20 curl -s http://127.0.0.1:8080/v1/models 2>/dev/null || true)
case "$live" in
  *iq3s*) echo "OK: strata is serving iq3s" ;;
  *) echo "FAIL: strata /v1/models does not report iq3s (engine down or old config?)" >&2; fail=1 ;;
esac
[ "$fail" -eq 0 ] || { echo "Refusing to delete anything." >&2; exit 1; }

# --- what would go, and what it actually frees ---
freed=0
report() { # path
  local p=$1
  [ -e "$p" ] || { echo "  (absent) $p"; return; }
  local sz nlink
  sz=$(stat -c %s "$p"); nlink=$(stat -c %h "$p")
  if [ "$nlink" -le 1 ]; then
    freed=$((freed + sz)); echo "  DELETE $p  ($(numfmt --to=iec "$sz"))"
  else
    echo "  UNLINK $p  ($(numfmt --to=iec "$sz"), ${nlink} links - frees 0, shared with IQ3_S)"
  fi
}
echo "To remove:"
report "$S1_OLD"
report "$S2_OLD"
if [ "$keep_pack" -eq 0 ] && [ -d "$PACK_OLD" ]; then
  psz=$(du -sb "$PACK_OLD" | cut -f1)
  freed=$((freed + psz)); echo "  DELETE $PACK_OLD  ($(numfmt --to=iec "$psz"))"
fi
echo "Would free: $(numfmt --to=iec "$freed")"

if [ "$yes" -eq 0 ]; then
  echo "(dry run - pass --yes to delete)"
  exit 0
fi

echo "Deleting..."
rm -f "$S1_OLD" "$S2_OLD"
if [ "$keep_pack" -eq 0 ]; then rm -rf "$PACK_OLD"; fi
echo "Done. shard 2 still present via $S2_IQ3S (same inode): $(stat -c '%i %s' "$S2_IQ3S" 2>/dev/null || echo MISSING)"
df -h "$GGUF_DIR" | tail -1
