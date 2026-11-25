#!/usr/bin/env bash
# Shared helpers for the fetch-*.sh model-file scripts.
#
# Usage: source this file, then call:
#   fetch_files <out-dir> <base-url> <check-only> <guard-gib> <manifest>
# where <manifest> is a string of "name bytes sha256" lines (one per file).
#
# The helper is idempotent: a file already present at the right size and
# hash is skipped; a partial file resumes (wget -c); a wrong-size or
# wrong-hash file is re-fetched. It returns 0 when everything is present
# and verified, 1 otherwise.

check_one() { # path bytes sha -> 0 ok, 1 mismatch
  local p=$1 bytes=$2 sha=$3
  [ -f "$p" ] && [ "$(stat -c %s "$p")" -eq "$bytes" ] || return 1
  echo "  verifying sha256 of $(basename "$p") ($(numfmt --to=iec "$bytes")) ..."
  echo "$sha  $p" | sha256sum -c - || return 1
  return 0
}

fetch_files() { # out-dir base-url check-only guard-gib manifest
  local out=$1 base=$2 check_only=$3 guard_gib=$4 manifest=$5
  mkdir -p "$out"

  if [ "$check_only" -eq 0 ] && [ "$guard_gib" -gt 0 ]; then
    local free_kb
    free_kb=$(df --output=avail -k "$out" | tail -1 | tr -d ' ')
    if [ "$free_kb" -le $((guard_gib * 1024 * 1024)) ]; then
      echo "only $((free_kb / 1024 / 1024)) GiB free on $out; the download needs more." >&2
      echo "Reclaim space first (old model sets, downloads, etc.)." >&2
      return 1
    fi
  fi

  local rc=0 name bytes sha dest
  while read -r name bytes sha; do
    [ -n "${name:-}" ] || continue
    dest="$out/$name"
    if check_one "$dest" "$bytes" "$sha"; then
      echo "OK   $name (already complete)"
      continue
    fi
    if [ "$check_only" -eq 1 ]; then
      echo "MISS $name (absent, short, or hash mismatch)"
      rc=1
      continue
    fi
    echo "GET  $name <- $base/$name"
    wget -c --tries=20 --timeout=60 --progress=dot:giga -O "$dest" "$base/$name" || {
      echo "wget failed for $name (re-run to resume)" >&2; rc=1; continue
    }
    check_one "$dest" "$bytes" "$sha" || { echo "HASH MISMATCH $name - delete it and re-run" >&2; rc=1; }
  done <<<"$manifest"

  return "$rc"
}
