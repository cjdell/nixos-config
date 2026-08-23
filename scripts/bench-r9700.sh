#!/usr/bin/env bash
# Benchmarks the R9700 (Radeon AI PRO R9700, Navi 48 / gfx1201, 32 GiB) with
# llama-bench, pinned to that GPU regardless of backend.
#
# Usage:
#   scripts/bench-r9700.sh <tag> <llama-bench-bin> [--hip|--vulkan] [model.gguf ...]
#
# Backend selection:
#   --vulkan (default): pins the R9700 via the mesa device-select layer
#     (MESA_VK_DEVICE_SELECT=1002:7551!) so it is Vulkan0; needs XDG_DATA_DIRS
#     for the implicit-layer manifest under /run/opengl-driver/share.
#   --hip:              pins via HIP_VISIBLE_DEVICES=0 (the R9700 is the first
#     HIP agent, see rocminfo); device name ROCm0. HSA_OVERRIDE_GFX_VERSION is
#     unset so a native gfx1201 build loads its own code objects.
#
# Default model pool: the R9700 production models + the Qwen3-8B Q8_0 the
# rdna-boosts fork is benchmarked against upstream on.
#
# Results land in bench-results/r9700/<tag>/ as
# <model>-pp<PP>-tg<TG>.md (+ .log for stderr). Re-runnable/idempotent.
set -euo pipefail

TAG="${1:?usage: bench-r9700.sh <tag> <llama-bench-bin> [--hip|--vulkan] [model ...]}"
BENCH="${2:?missing llama-bench binary}"
shift 2

BACKEND=vulkan
case "${1:-}" in
  --hip) BACKEND=hip; shift ;;
  --vulkan) BACKEND=vulkan; shift ;;
esac

MODELS=("$@")
if [ ${#MODELS[@]} -eq 0 ]; then
  MODELS=(
    /home/cjdell/Models/Qwen3.8-27B-UD-Q4_K_XL.gguf
    /home/cjdell/Models/Qwen3-Coder-REAP-25B-A3B-Rust-Q4_K_M.gguf
    /home/cjdell/Models/Qwen3-8B-Q8_0.gguf
  )
fi

OUT="bench-results/r9700/${TAG}"
mkdir -p "$OUT"

# Match the production router config: 12 threads, all layers on GPU, q8_0 KV.
# llama-bench wants the integer sentinel 999 for "all layers" (-ngl all is not
# accepted and fails with "invalid range format").
COMMON=(-t 12 -ngl 999 -ctk q8_0 -ctv q8_0 -r 5)
case "$BACKEND" in
  vulkan)
    export XDG_DATA_DIRS=/run/opengl-driver/share
    export MESA_VK_DEVICE_SELECT=1002:7551!
    DEV=(-dev Vulkan0)
    ;;
  hip)
    export HIP_VISIBLE_DEVICES=0
    unset HSA_OVERRIDE_GFX_VERSION 2>/dev/null || true
    DEV=(-dev ROCm0)
    ;;
  *)
    echo "unknown backend: $BACKEND" >&2
    exit 2
    ;;
esac

echo "== $(basename "$BENCH") backend=$BACKEND tag=$TAG -> $OUT"
"$BENCH" --list-devices || true

for m in "${MODELS[@]}"; do
  [ -f "$m" ] || { echo "SKIP (missing): $m"; continue; }
  name=$(basename "$m" .gguf)
  for pg in pp512,tg128 pp1024,tg256; do
    pp=${pg%%,*}; tg=${pg##*,}
    echo "== $name $pg"
    timeout 3600 "$BENCH" "${COMMON[@]}" "${DEV[@]}" -p "${pp#pp}" -n "${tg#tg}" \
      -m "$m" -o md >"$OUT/${name}-${pg}.md" 2>"$OUT/${name}-${pg}.log" \
      || { echo "FAILED $name $pg (see ${name}-${pg}.log)"; tail -5 "$OUT/${name}-${pg}.log"; }
  done
done

echo "DONE -> $OUT"
