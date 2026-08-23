#!/usr/bin/env bash
# Side-by-side llama-bench comparison for the R9700 before/after a backend or
# build change. Reads two bench-results/r9700/<tag>/ dirs produced by
# bench-r9700.sh and prints a per-(model, test) table with the % change.
#
# Usage: scripts/bench-compare.sh <before-tag> <after-tag>
set -euo pipefail

BEFORE="bench-results/r9700/${1:?usage: bench-compare.sh <before-tag> <after-tag>}"
AFTER="bench-results/r9700/${2:?missing after-tag}"
[ -d "$BEFORE" ] || { echo "no such dir: $BEFORE" >&2; exit 1; }
[ -d "$AFTER" ] || { echo "no such dir: $AFTER" >&2; exit 1; }

# Extract "test | t/s" rows from a single bench .md file: prints
# "<test>\t<t/s>" with the ± error dropped.
extract() {
  awk -F'|' '
    /^\|/ && !/model.*size.*params.*backend/ && !/^ *\| *--/ && NF >= 13 {
      test=$11; sub(/^ +/, "", test); sub(/ +$/, "", test)
      tps=$12; sub(/^ +/, "", tps); sub(/ +$/, "", tps)
      sub(/ ± .*/, "", tps)
      if (tps != "" && tps !~ /^[0-9.]+$/) next
      printf "%s\t%s\n", test, tps
    }' "$1"
}

printf "%-14s | %-30s | %14s | %14s | %8s\n" "test" "model" "before(t/s)" "after(t/s)" "delta"
printf "%s\n" "-----------------------------------------------------------------------------------------------------"

for before_md in "$BEFORE"/*.md; do
  fname=$(basename "$before_md")
  after_md="$AFTER/$fname"
  [ -f "$after_md" ] || continue
  # model name = file name without -ppNNN-tgNNN.md
  model=${fname%-pp[0-9]*}
  while IFS=$'\t' read -r test before_tps; do
    after_tps=$(awk -F'\t' -v t="$test" '$1 == t { print $2 }' <(extract "$after_md"))
    if [ -n "$after_tps" ]; then
      delta=$(awk -v b="$before_tps" -v a="$after_tps" 'BEGIN { printf "%+.1f%%", (a - b) / b * 100 }')
    else
      after_tps="-"; delta="-"
    fi
    printf "%-14s | %-30s | %14s | %14s | %8s\n" "$test" "$model" "$before_tps" "$after_tps" "$delta"
  done < <(extract "$before_md")
done

echo
echo "faster (negative prefill deltas may be noise; generation deltas are what matter for chat)"
