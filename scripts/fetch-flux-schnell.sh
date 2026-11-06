#!/usr/bin/env bash
# Fetch the Flux-schnell weights for the sd-server service
# (hosts/zen3-nixos/ai/sd-server.nix) into /home/cjdell/sd-models.
#
# Sizes + sha256s are the LFS pointers of the HF files as verified
# 2026-11-06. curl -C - resumes a partial download; a wrong-size or
# wrong-sha file is re-fetched from scratch.
#
#   ./scripts/fetch-flux-schnell.sh           # fetch what is missing/broken
#   ./scripts/fetch-flux-schnell.sh --check   # verify only, download nothing
set -euo pipefail

DEST="${FLUX_DEST:-/home/cjdell/sd-models}"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

# name|url|bytes|sha256
FILES=(
  "flux1-schnell-Q8_0.gguf|https://huggingface.co/city96/FLUX.1-schnell-gguf/resolve/main/flux1-schnell-Q8_0.gguf|12687821728|f6694941193b10148dbf1f0f498d4ccd3e9875c127fc53946213b68580c66f10"
  "t5xxl_fp8_e4m3fn_scaled.safetensors|https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp8_e4m3fn_scaled.safetensors|5157348688|a498f0485dc9536735258018417c3fd7758dc3bccc0a645feaa472b34955557a"
  "clip_l.safetensors|https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors|246144152|660c6f5b1abae9dc498ac2d21e1347d2abdb0cf6c0c0c8576cd796491d9a6cdd"
  "ae.safetensors|https://huggingface.co/camenduru/FLUX.1-dev/resolve/main/ae.safetensors|335304388|afc8e28272cd15db3919bacdb6918ce9c1ed22e96cb12c4d5ed0fba823529e38"
)

mkdir -p "$DEST"
rc=0
for entry in "${FILES[@]}"; do
  IFS='|' read -r name url want_bytes want_sha <<<"$entry"
  out="$DEST/$name"

  have=$(stat -c%s "$out" 2>/dev/null || echo 0)
  if [ "$have" = "$want_bytes" ] && echo "$want_sha  $out" | timeout 600 sha256sum --check --quiet -; then
    echo "ok       $name"
    continue
  fi

  if [ "$CHECK_ONLY" = 1 ]; then
    echo "CHECK FAILED  $name ($have of $want_bytes bytes)"
    rc=1
    continue
  fi

  if [ "$have" = "$want_bytes" ]; then
    echo "wrong sha256, re-fetching $name"
    rm -f "$out"
    have=0
  fi

  echo "fetching   $name ($(numfmt --to=iec "$want_bytes" 2>/dev/null || echo "$want_bytes"))"
  resume=(-C -)
  [ -f "$out" ] || resume=()
  timeout 86400 curl -fL "${resume[@]}" --retry 3 --connect-timeout 15 -o "$out" "$url"

  have=$(stat -c%s "$out")
  if [ "$have" != "$want_bytes" ]; then
    echo "WRONG SIZE  $name: $have of $want_bytes"
    rc=1
  elif ! echo "$want_sha  $out" | timeout 600 sha256sum --check --quiet -; then
    echo "WRONG SHA256  $name"
    rc=1
  else
    echo "done       $name"
  fi
done

exit "$rc"
