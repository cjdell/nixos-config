#!/usr/bin/env bash
# qwen36-256k-check.sh — readiness + the actual measurement for the
# Qwen3.6-35B-A3B 262,144-token lane (hosts/zen3-nixos/ai/strata.nix's
# qwen36-256k-fp8 / qwen36-256k-fp4 entries, engine 0.1.67 from
# ./strata-q36-package.nix).  Design doc: docs/qwen36-256k-vram.md.
#
# THE QUESTIONS IT ANSWERS, in the order that matters:
#   1. does the build actually parse --kv?  No GPU needed: `kv-check`.  On
#      engine 0.1.67 `--kv bogus` says "takes fp32, fp16, fp8 or fp4"; on the
#      pinned 0.1.59.1 the flag is swallowed ("ignoring --kv ... not an option
#      of this engine") and the run goes hybrid — which is the whole trap.
#   2. at 262,144, is EVERY expert resident, or did we land in the hybrid
#      CPU-pool mode?  Read that from the engine's own placement lines and from
#      free VRAM — NEVER inferred from tok/s (docs/qwen36-256k-vram.md,
#      "The test later").
#   3. what does decode cost when the window is actually FULL?  Upstream's fill
#      table (their docs/bench-results/2026-11-20-q36-kv-precision/) is the
#      warning: 84.3 -> 6.8 tok/s between 305 and 126,367 cells in the SAME
#      window, because this engine's attention is dense split-K with no
#      indexer — the read scales with fill, not with window.  Their card held
#      the experts on the CPU (--expert-vram 0.1), so their absolute number is
#      NOT ours; the SHAPE is what we measure, on a box where the whole model
#      fits.  That is exactly what `probe`'s short-fill control vs long-fill
#      arm separates.
#
# NOTHING HERE TOUCHES THE LIVE ENGINE unless you pass `go`, and `go` refuses
# when a request is in flight.  `status` and `kv-check` are read-only and do no
# building either (they say what to build).
#
# Usage:
#   scripts/qwen36-256k-check.sh                      # == status
#   scripts/qwen36-256k-check.sh status                # what is live, free VRAM, what is built
#   scripts/qwen36-256k-check.sh kv-check              # the --kv parser, new vs pinned (idle GPU)
#   scripts/qwen36-256k-check.sh go fp4 [--fill N]     # EXCLUSIVE: stop the live lane, start fp4, measure
#   scripts/qwen36-256k-check.sh go 128kfp8            # the measured best everyday lane (131072 + fp8 KV)
#   scripts/qwen36-256k-check.sh single MODEL 122000   # ONE arm against an already-live lane
#   scripts/qwen36-256k-check.sh probe [MODEL_ID]      # fill probe against an ALREADY-live lane
#   scripts/qwen36-256k-check.sh restore               # put back whatever `go` stopped
#
# `go` is GPU-exclusive by construction.  Say which host and which lane you are
# stopping before you run it, and remember the standing warning: a
# nixos-rebuild switch that touches these lanes can leave strata.service up and
# the partner stopped.
set -uo pipefail

SWAP=:8080                      # the shim: same URL as always, swaps on `model`
LANES=(strata strata-coder-iq1m strata-qwen36-ud-q4-k-xl strata-qwen36-128k-fp8 strata-qwen36-256k-fp8 strata-qwen36-256k-fp4)
MODEL_FP8=qwen3.6-35b-a3b-ud-q4_k_xl-fp8
MODEL_FP4=qwen3.6-35b-a3b-ud-q4_k_xl-fp4
OUT=${OPENCODE_SESSION_DIR:-/tmp}/qwen36-256k
LAST=/tmp/opencode/qwen36-256k-last-lane

hr() { printf '%s\n' "------------------------------------------------------------"; }
say() { printf '%s\n' "$*"; }

# amd-smi's free VRAM, MB.  `metric -m --json` -> gpu_data[0].mem_usage.
# free_vram.{value,unit}: the value sits on the line AFTER the key, so awk
# grabs the next line.  620 on this box with Flash-Next loaded, ~32000 idle —
# which is the whole residency signal, so it is read the same way every time.
free_vram() {
  timeout 25 amd-smi metric -m --json 2>/dev/null |
    awk '/"free_vram"/{f=1; next} f && /"value"/{gsub(/[^0-9]/,""); print; exit}'
}

# The store path of a flake attr WITHOUT building it, "" if it is not there.
out_path() { timeout 120 nix eval --raw "$1.outPath" 2>/dev/null || true; }

rocm10_lib() { ls -d /nix/store/*-rocm10-runtime-*/lib 2>/dev/null | sort | tail -1; }

live_engine() {
  timeout 10 curl -s "http://127.0.0.1$SWAP/v1/status" 2>/dev/null
}

status() {
  say "== host: $(hostname)  (the card belongs to whoever holds the gpu-mode lease) =="
  say "gpu-mode: $(timeout 10 gpu-mode status 2>/dev/null | head -3 | tr '\n' ' ')"
  hr
  say "== what :8080 answers now =="
  local st
  st=$(live_engine)
  if [ -n "$st" ]; then
    echo "$st" | tr ',' '\n' |
      grep -E '"model"|"loaded"|"engine"|"in_flight"|"max_positions"|"used_mib"|"total_mib"|"predicted_per_second"|"prompt_per_second"' |
      sed 's/^/  /'
  else
    say "  (nothing answering — card off-lease, or no engine running)"
  fi
  hr
  say "== free VRAM.  ~3-6 GiB free after a 262K start = resident.  ~0 = spilled. =="
  say "  free_vram: $(free_vram) MB"
  hr
  say "== engine units on this system (LoadState=not-found means the working tree is not deployed) =="
  for u in "${LANES[@]}"; do
    printf '  %-32s %-10s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null)" \
      "$(systemctl show "$u" -p LoadState --value 2>/dev/null)"
  done
  hr
  say "== the 0.2.21 engine this lane needs (evaluated, not built) =="
  local p
  p=$(out_path '.#strata-q36')
  if [ -z "$p" ]; then
    say "  .#strata-q36 does not evaluate — check hosts/zen3-nixos/ai/strata-q36-package.nix"
  elif [ -x "$p/bin/strata-q36" ]; then
    say "  BUILT  $p"
  else
    say "  NOT BUILT  $p"
    say "  build it with: nix build .#strata-q36   (engine-only target, no Qwen3.8 engine)"
  fi
  hr
  say "== model files (nothing is downloaded here; see scripts/fetch-strata-qwen36-35b-a3b.sh --list) =="
  ls -la /home/cjdell/Models/Qwen3.6-35B-A3B-MTP-GGUF/ 2>/dev/null | sed 's/^/  /'
  say "  free on /home: $(df -h /home | tail -1 | awk '{print $4" ("$5" used)"}')"
  say "  tokenizer pack: $(ls /home/cjdell/Strata/pack/qwen36-ud-q4-k-xl/tokenizer/vocab.json 2>/dev/null || echo MISSING)"
  hr
  say "next: kv-check (no GPU), then go fp4 (exclusive)."
}

kv_check() {
  say "== does the build parse --kv?  (bad value -> exit 2; no GPU work) =="
  local p old rocm
  rocm=$(rocm10_lib)
  # No `${rocm:-…}` with prose inside it: bash's brace scanner treats an
  # apostrophe in that position as opening a quote (it burned this script once).
  if [ -n "$rocm" ]; then
    say "  runtime ROCm: $rocm"
  else
    say "  runtime ROCm: none found — the binary's RUNPATH (nixpkgs ROCm) will be used"
  fi
  p=$(out_path '.#strata-q36')
  if [ -z "$p" ]; then say "  .#strata-q36 does not evaluate"; return 1; fi
  if [ ! -x "$p/bin/strata-q36" ]; then
    say "  not built yet: nix build .#strata-q36   (then re-run)"
    return 1
  fi
  say "  binary: $p/bin/strata-q36"
  local out
  out=$(LD_LIBRARY_PATH="${rocm:+$rocm}:${LD_LIBRARY_PATH:-}" timeout 60 "$p/bin/strata-q36" --kv bogus 2>&1)
  say "  output: $(echo "$out" | head -4 | tr '\n' '|')"
  if echo "$out" | grep -q 'takes fp32, fp16, fp8 or fp4'; then
    say "  PASS — the 0.1.6x KV widths are compiled in. The 256K lane may be started."
  elif echo "$out" | grep -q 'ignoring --kv'; then
    say "  FAIL — this build swallows --kv (0.1.59.1 behaviour). Do NOT start the 256K lane."
    return 1
  else
    say "  INCONCLUSIVE — read the line above. A loader error means the ROCm path is wrong,"
    say "  not that the build is; fix LD_LIBRARY_PATH (rocm10_runtime: ${rocm:-none}) and retry."
    return 1
  fi
  hr
  say "== the same check on the PINNED engine, by its strings (never launch a second engine to ask) =="
  old=$(out_path '.#strata')
  if [ -n "$old" ] && [ -x "$old/bin/strata" ]; then
    say "  pinned binary: $old/bin/strata"
    say "  serve catch-all ('not an option of this engine'): $(grep -ac 'not an option of this engine' "$old/bin/strata") (1 = it swallows unknown flags)"
    say "  --kv width strings:                              $(grep -ac 'takes fp32, fp16, fp8 or fp4' "$old/bin/strata") (0 = no --kv on the q36 path here)"
    say "  new binary  --kv width strings:                  $(grep -ac 'takes fp32, fp16, fp8 or fp4' "$p/bin/strata-q36") (1 = the widths are compiled in)"
  else
    say "  .#strata not built"
  fi
}

# One probe: a fresh nonce every call so nothing is reused from the last one,
# and the prompt size REPORTED (usage.prompt_tokens), never estimated.
# $1 model, $2 target tokens (0 = the short-fill control), $3 tokens to generate
fill_probe() {
  local model=$1 target=$2 gen=${3:-128}
  local nonce chars bodyfile resp pn tn pp pps wall ratio attempt toolarge
  nonce=$(head -c 32 /dev/urandom | md5sum | cut -c1-10)
  mkdir -p "$OUT"
  bodyfile="$OUT/body.json"
  # chars/token for this filler is not stable: random base36 lands anywhere in
  # 0.60-0.72 chars/token depending on the draw (the tokenizer splits
  # single-character runs). So the FIRST long arm measures it (chars /
  # prompt_n) and later arms size themselves from the measurement — AND an
  # overshoot is not a lost run: the engine answers a 400 naming the real
  # prompt size, and the arm is re-sized from that and retried once.
  ratio=$(cat "$OUT/ratio" 2>/dev/null || echo 0.66)
  for attempt in 1 2; do
    if [ "$target" -gt 0 ]; then
      chars=$(awk -v t="$target" -v r="$ratio" 'BEGIN{printf "%d", t*r}')
      # Straight into the file: a ~750 KB body is far past MAX_ARG_STRLEN
      # (128 KB), so `curl --data-binary "$body"` dies with E2BIG and the probe
      # silently measures nothing. That is exactly the bug this line fixes.
      tr -dc 'a-z0-9' < /dev/urandom | head -c "$chars" | fold -w 12 |
        awk -v n="$nonce" '{print n $0}' | tr '\n' ' ' > "$OUT/filler.txt"
      printf '{"model":"%s","messages":[{"role":"user","content":"' "$model" > "$bodyfile"
      cat "$OUT/filler.txt" >> "$bodyfile"
      printf ' %s Now reply with the single word READY."}],"max_tokens":%d,"temperature":0,"stream":false}' \
        "$nonce" "$gen" >> "$bodyfile"
    else
      # JSON-safe by construction: filler is [a-z0-9 ] and the nonce is hex.
      printf '{"model":"%s","messages":[{"role":"user","content":"%s %s Now reply with the single word READY."}],"max_tokens":%d,"temperature":0,"stream":false}' \
        "$model" "$nonce" "$nonce" "$gen" > "$bodyfile"
    fi
    resp=$(timeout 2400 curl -s -X POST "http://127.0.0.1$SWAP/v1/chat/completions" \
      -H 'content-type: application/json' --data-binary "@$bodyfile")
    toolarge=$(printf '%s' "$resp" | sed -n 's/.*exceeds the context window: prompt (\([0-9]*\) tokens.*/\1/p' | head -1)
    [ -n "$toolarge" ] && [ "$attempt" = 1 ] || break
    # Recompute chars/token from what the engine just told us: `chars` produced
    # `toolarge` tokens, so the next draw needs chars/token = chars/toolarge.
    ratio=$(awk -v c="$chars" -v n="$toolarge" 'BEGIN{printf "%.4f", c/n}')
    say "  (prompt was $toolarge tokens > window; re-sizing chars/token to $ratio and retrying)"
  done
  # The engine reports its own timings: prompt (prefill) and predicted
  # (decode) separately, with MTP's draft acceptance. Wall-clock is useless
  # here because the long arm spends minutes in prefill.  Note the SPACES
  # ("prompt_n": 36) — a pattern of `":\([0-9]*\)` matches nothing and reports
  # "?" while looking like it worked.
  pn=$(printf '%s' "$resp" | tr ',' '\n' | sed -n 's/.*"prompt_n": *\([0-9]*\).*/\1/p' | head -1)
  tn=$(printf '%s' "$resp" | tr ',' '\n' | sed -n 's/.*"predicted_n": *\([0-9]*\).*/\1/p' | head -1)
  pp=$(printf '%s' "$resp" | tr ',' '\n' | sed -n 's/.*"prompt_per_second": *\([0-9.]*\).*/\1/p' | head -1)
  pps=$(printf '%s' "$resp" | tr ',' '\n' | sed -n 's/.*"predicted_per_second": *\([0-9.]*\).*/\1/p' | head -1)
  wall=$(printf '%s' "$resp" | tr ',' '\n' | sed -n 's/.*"predicted_ms": *\([0-9.]*\).*/\1/p' | head -1)
  local draft acc
  draft=$(printf '%s' "$resp" | tr ',' '\n' | sed -n 's/.*"draft_n": *\([0-9]*\).*/\1/p' | head -1)
  acc=$(printf '%s' "$resp" | tr ',' '\n' | sed -n 's/.*"draft_n_accepted": *\([0-9]*\).*/\1/p' | head -1)
  say "  prompt_n=${pn:-?}  prefill=${pp:-?} tok/s  |  predicted_n=${tn:-?}  decode=${pps:-?} tok/s  (${wall:-?} ms, MTP ${acc:-?}/${draft:-?} accepted)"
  say "  free VRAM after: $(free_vram) MB"
  # Calibration for the next arm (only from a real, non-trivial answer).
  if [ "${pn:-0}" -gt 1000 ] 2>/dev/null; then
    awk -v c="$chars" -v n="$pn" 'BEGIN{printf "%.3f", c/n}' > "$OUT/ratio"
    say "  chars/token measured: $(cat "$OUT/ratio")"
  fi
  [ -n "$resp" ] && printf '%s' "$resp" > "$OUT/last-probe.json"
  printf '%s' "$resp" | grep -o '"error":[^}]*}' | head -1 | sed 's/^/  ERROR: /' || true
}

probe() {
  local model=${1:-$MODEL_FP4} fill=${2:-}
  mkdir -p "$OUT"
  rm -f "$OUT/ratio"   # re-calibrate for this run's filler draw
  # Size the arms from the LIVE window, not from a constant: the same tool has
  # to measure the 128K lane against the pinned curve in this lane's own log
  # (/var/lib/strata-qwen36-ud-q4-k-xl/strata.log, Nov 23: 107 tok/s at 49
  # cells, 27.5 at 49,516, 19.5 at 67,703, drafts 0 of 0) as well as the 256K
  # pair.  max_positions is the engine's own number.
  local win
  win=$(live_engine | tr ',' '\n' | sed -n 's/.*"max_positions": *\([0-9]*\).*/\1/p' | head -1)
  [ -n "$win" ] || { say "no live engine to size the probe against (start a lane first)"; return 1; }
  [ -n "$fill" ] || fill=$((win * 93 / 100))
  say "== fill probe, model=$model.  Window is FIXED ($win); only FILL moves. =="
  say "  Same window, same weights, same MTP depth: the control and the arms"
  say "  differ in prompt length alone, so the delta IS the cost of a fuller"
  say "  cache — the number upstream's fill table warns about (their card held"
  say "  the experts on the CPU; ours does not, which is why we measure)."
  say "-- control (no fill)"
  fill_probe "$model" 0 128
  say "-- mid fill (~$((win / 2)) cells)"
  fill_probe "$model" $((win / 2)) 128
  say "-- near-full (~$fill cells)"
  fill_probe "$model" "$fill" 128
  hr
  say "Read the placement/hybrid lines the engine said, do not guess them:"
  say "  sudo journalctl -u strata-qwen36-256k-fp4 --since '-30 min' | grep -iE 'kv|expert|hybrid|resident|VRAM|pool|fit'"
  say "  sudo grep -iE 'kv |expert|hybrid|resident|pool' /var/lib/strata-qwen36-256k-*/strata.log | tail -30"
}

go() {
  local width=${1:-fp4}
  # Empty = let probe size the arms from the live window (the 128K A/B lane's
  # window is half this lane's; a 245000-cell target there is a guaranteed 400).
  local fill=
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --fill) fill=${2:-}; shift ;;
      *) say "ignoring argument: $1" ;;
    esac
    shift
  done
  local model unit
  case "$width" in
    fp8) model=$MODEL_FP8 ;;
    fp4) model=$MODEL_FP4 ;;
    # 131072 with the cache narrowed: the measured best everyday lane.
    128kfp8) model=qwen3.6-35b-a3b-ud-q4_k_xl-128k-fp8 ;;
    *)
      say "lane must be fp8, fp4 or 128kfp8"
      exit 2
      ;;
  esac
  case "$width" in
    128kfp8) unit="strata-qwen36-128k-fp8" ;;
    *) unit="strata-qwen36-256k-$width" ;;
  esac

  # Never interrupt a running generation.
  local inflight
  inflight=$(live_engine | tr ',' '\n' | sed -n 's/.*"in_flight":\([0-9]*\).*/\1/p' | head -1)
  if [ "${inflight:-0}" != "0" ]; then
    say "REFUSING: ${inflight:-?} request(s) in flight on :8080. Let the lane drain (status), then re-run."
    exit 1
  fi
  local p
  p=$(out_path '.#strata-q36')
  [ -n "$p" ] && [ -x "$p/bin/strata-q36" ] || { say ".#strata-q36 is not built; nix build .#strata-q36 first."; exit 1; }

  mkdir -p "$OUT"
  local live
  live=$(for u in "${LANES[@]}"; do [ "$(systemctl is-active "$u" 2>/dev/null)" = active ] && echo "$u"; done | head -1)
  echo "${live:-none}" > "$LAST"
  say "== $(hostname): stopping '${live:-nothing}' and starting '$unit' (GPU-exclusive) =="
  say "  free before: $(free_vram) MB"
  [ "$live" = "$unit" ] || sudo systemctl stop "${LANES[@]}"
  sudo systemctl start "$unit"
  say "  started $unit — a 21 GiB GGUF read is minutes; polling for loaded:true"
  local i ok=0
  for i in $(seq 1 120); do
    if live_engine | grep -q '"loaded": *true'; then ok=1; say "  loaded after ~$((i * 10))s"; break; fi
    sleep 10
    [ $((i % 9)) -eq 0 ] && say "   ... still loading ($((i * 10))s), free $(free_vram) MB"
  done
  [ "$ok" = 1 ] || say "  NOT loaded within 20 min — read: sudo journalctl -u $unit -n 80 --no-pager"
  live_engine | tr ',' '\n' | grep -E '"model"|"loaded"|"engine"|"max_positions"|"used_mib"' | sed 's/^/  /' || true
  hr
  say "== residency, from the engine (NOT from tok/s) =="
  sudo journalctl -u "$unit" --since '-25 min' --no-pager 2>/dev/null |
    grep -iE 'kv|expert|hybrid|resident|VRAM|pool|session|fit|chunk' | tail -30 | sed 's/^/  /' || true
  say "  free VRAM now: $(free_vram) MB   (3-6 GiB = every expert resident; ~0 = CPU pool)"
  hr
  probe "$model" "$fill" 2>&1 | tee "$OUT/probe-$width.txt"
  hr
  say "done — the live lane is '$unit'. Put back what was running: $0 restore"
}

restore() {
  local prev
  prev=$(cat "$LAST" 2>/dev/null || echo strata)
  [ "$prev" != none ] || prev=strata
  say "== $(hostname): restoring $prev =="
  sudo systemctl stop "${LANES[@]}" 2>/dev/null || true
  sudo systemctl start "$prev"
  say "  started $prev — check: timeout 10 curl -s http://127.0.0.1:8080/v1/status | head -c 300"
}

# One arm only, against an ALREADY-live lane: `single MODEL [FILL]`. For the
# case where the curve is half-measured (an arm was refused for size) and you
# do not want to pay for the arms you already have.
single() {
  local model=${1:-$MODEL_FP4} fill=${2:-245000}
  mkdir -p "$OUT"
  say "== single arm: model=$model target=$fill cells =="
  fill_probe "$model" "$fill" 128
}

case "${1:-status}" in
  status) status ;;
  kv-check) kv_check ;;
  probe) shift; probe "${1:-$MODEL_FP4}" "${2:-}" ;;
  single) shift; single "${1:-$MODEL_FP4}" "${2:-245000}" ;;
  go) shift; go "$@" ;;
  restore) restore ;;
  -h|--help|help) sed -n '2,40p' "$0" ;;
  *) echo "unknown subcommand: $1 (status|kv-check|probe|single|go|restore)" >&2; exit 2 ;;
esac
