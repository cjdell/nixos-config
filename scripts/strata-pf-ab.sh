#!/usr/bin/env bash
# strata-pf-ab.sh — A/B a Strata prompt-path switch against this box's real traffic.
#
# Built for STRATA_PF_FUSED_Q50 (the fused int8 kernel for the Q5_0 `down` layers —
# 33 of the 48 expert layers in UD-IQ4_XS v31), and useful for any other
# prompt-path switch (STRATA_PF_FUSED_Q50, STRATA_SELECT_WMMA, STRATA_MMQ_KQ,
# STRATA_PREFILL_CPU_SHARE…). It measures cold prefill, so it answers the only
# question that matters for these switches: does a prompt-path win reach a box
# whose prompts are almost entirely KV-reused?
#
# Why the prompts are built the way they are:
#   * COLD by construction — a unique nonce as the FIRST line defeats the
#     conversation cache, which matches on exact token prefix, so nothing is
#     reused (check: `+ N read` in strata.log equals the whole prompt).
#   * IDENTICAL between arms — the needle value is derived from (depth, rep), not
#     $RANDOM, so both runs ask the same question at the same depth and the only
#     difference is the env switch. The nonce still differs (that is what keeps
#     them cold) and does not affect retrieval.
#   * a deep NEEDLE near the end of every prompt, because the switches that pay
#     usually "change the arithmetic of those layers" (upstream's words): correct
#     retrieval at depth is the cheap quality gate alongside the speed number.
#   * the reply is read from content AND reasoning_content — this model often
#     spends a short budget entirely in the thinking channel (content: null),
#     which is normal and not a failure (see docs/strata.md).
#
# Set the switch on ONE side only: add/remove env.STRATA_PF_FUSED_Q50 in
# hosts/zen3-nixos/ai/strata.nix, `nixos-rebuild switch --flake .#zen3-nixos`,
# wait for /v1/status loaded:true, then run this script with a different LABEL.
# Restarting strata restarts whatever agent session you are typing in, so run
# the switch detached and poll it.
#
# usage: scripts/strata-pf-ab.sh <label> [bytes...]
#        (default depths 28800 115200 345600 ≈ 8.7K / 36.1K / 108.7K tokens on the corpus)
#
# RESULT (2026-11-10, Strata 0.2.13.1 / engine 0.1.59.1, UD-IQ4_XS v31, R9700):
#   cold prompt      off     on     delta        STRATA_PF_FUSED_Q50=1
#   8.7K tokens     2161 →  2672   +24 %
#   36.1K tokens    2671 →  2804   +5 %
#   108.7K tokens   3113 →  3293   +5.8 %
#   decode unchanged (55-76 tok/s both arms: a prefill-only switch), needle correct
#   in all 9 runs. But across 58,154 logged requests this box's cold-read size is
#   p50 223 / p90 1.9K / p99 34K tokens (91 % under 4K), so that curve is worth
#   0.08 s per request on average — the switch was left OFF. Treat a single slow
#   rep at 8K as noise (one 246 tok/s read did not reproduce in three reruns).
set -uo pipefail
LABEL="${1:-run}"; shift || true
BYTES_LIST=("${@:-28800 115200 345600}")
OUT=/tmp/opencode/pf-bench-$LABEL.tsv
CORPUS=/tmp/opencode/corpus.txt
S=${STRATA_URL:-http://127.0.0.1:8080}
MODEL=${STRATA_MODEL:-qwen3.8-flash-next-unsloth-ud-iq4-xs-v31}
JQ=(nix shell nixpkgs#jq --command jq)

# ~3.6 bytes/token for this corpus; any distinct prose works, bigger prompts just
# truncate it. docs/ is 615 KB, enough for the 345600-byte (~109K token) depth.
if [ ! -s "$CORPUS" ]; then
  cat ~/nixos-config/docs/*.md ~/nixos-config/crates/*/README.md > "$CORPUS" 2>/dev/null
  echo "corpus: $(wc -c < "$CORPUS") bytes"
fi
: > "$OUT"

for BYTES in $BYTES_LIST; do
  for REP in 1 2; do
    WANT=$(( (BYTES / 1000 * 3 + REP * 7) % 900 + 100 ))   # deterministic needle value
    MARK="MARKER-7$REP$BYTES"
    {
      printf 'pf-bench nonce %s-%s-%s\n' "$BYTES" "$REP" "$LABEL"
      head -c "$BYTES" "$CORPUS"
      printf '\n%s: the calibrated spill threshold for this run is %s millikelvin.\n' "$MARK" "$WANT"
      printf '\nQuestion: what is the calibrated spill threshold stated near the end of the text above? Answer with the number and its unit only.\n'
    } > /tmp/opencode/prompt.txt
    "${JQ[@]}" -Rs --arg m "$MODEL" \
      '{model:$m, messages:[{role:"user",content:.}], max_tokens:320, temperature:0, stream:false}' \
      < /tmp/opencode/prompt.txt > /tmp/opencode/prompt.json
    timeout 900 curl -s -X POST "$S/v1/chat/completions" -H 'content-type: application/json' \
      --data @/tmp/opencode/prompt.json -o /tmp/opencode/pf-resp.json
    sleep 2
    # one slot, so last_timings after the response is this request's timings
    st=$(timeout 10 curl -s "$S/v1/status")
    TIM=$(printf '%s' "$st" | "${JQ[@]}" -c '.last_timings | {prompt_n,prompt_per_second,predicted_per_second,draft_n,draft_n_accepted}')
    REPLY=$("${JQ[@]}" -r '[.choices[0].message.content, .choices[0].message.reasoning_content] | map(tostring) | join(" ")' /tmp/opencode/pf-resp.json 2>/dev/null | tr '\n' ' ')
    GOT=$(printf '%s' "$REPLY" | grep -oE '[0-9]{3} millikelvin' | tail -1 | grep -oE '[0-9]+' || true)
    printf '%s\t%s\t%s\twant=%s\tgot=%s\t%s\n' "$LABEL" "$BYTES" "$REP" "$WANT" "${GOT:-none}" "$TIM" >> "$OUT"
    tail -1 "$OUT"
  done
done
echo "done: $OUT"
