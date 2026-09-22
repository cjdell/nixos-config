#!/usr/bin/env bash
# deploy-meter-relay.sh — deploy the meter-relay-rs Rust relay to grafton-router.
#
# The service is built from the `meter-relay-rs` path input
# (/home/cjdell/Projects/meter-relay-rs) declared in this repo's flake.nix.
# A `path:` input is FROZEN at the narHash recorded in flake.lock, so editing
# the Rust repo changes nothing until that entry is rewritten. Without the
# re-lock a plain `nixos-rebuild switch` rebuilds the old snapshot and systemd
# does not even restart the unit (ExecStart is unchanged) — the host keeps
# running the previous binary while `nix build` inside the Rust repo happily
# reports a fresh build. This script drives the loop:
#
#   1. sanity-check the Rust checkout (warns about untracked NEW files: when you
#      `nix build` in that repo Nix reads it through the git fetcher, so a file
#      that is not at least staged is invisible to the build; build it with
#      `--no-link` so no stale ./result symlink is left behind)
#   2. note the currently-deployed store path (nix eval … ExecStart)
#   3. re-lock the input: nix flake update meter-relay-rs
#   4. print the new store path and stop if it did not change
#   5. sudo nixos-rebuild switch --flake .
#   6. sudo nixos-confirm — grafton-router has autoRollback (see AGENTS.md)!
#   7. verify the unit runs the new path and the dashboard answers on :8484
#
# Usage: ./scripts/deploy-meter-relay.sh [options]
#   --no-rebuild   re-lock and report only; do not switch anything
#   --force        switch even when the input's store path did not change
#   -h|--help      show this help
#
# Run WITHOUT sudo (sudo is used internally for the rebuild + confirm), from
# this repo's checkout ON grafton-router. A switch only affects the machine it
# runs on, so the script refuses to rebuild anywhere else (--no-rebuild still
# works there, for refreshing the lock).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

MR_REPO="${MR_REPO:-/home/cjdell/Projects/meter-relay-rs}"
HOST="grafton-router"
INPUT="meter-relay-rs"
EXEC_START_ATTR=".#nixosConfigurations.${HOST}.config.systemd.services.meter-relay.serviceConfig.ExecStart"

DO_REBUILD=1
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --no-rebuild) DO_REBUILD=0 ;;
    --force) FORCE=1 ;;
    -h | --help)
      sed -n '2,30p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "unknown option: $1 (try --help)" >&2
      exit 2
      ;;
  esac
  shift
done

say() { printf '\n== %s\n' "$*"; }

exec_start() {
  # stdout only: nix prints its evaluation warnings on stderr
  nix eval --raw "$EXEC_START_ATTR" 2>/dev/null
}

# --- 1. the Rust checkout -----------------------------------------------------
[ -d "$MR_REPO/.git" ] || {
  echo "ERROR: $MR_REPO is not a git checkout (set MR_REPO=…)" >&2
  exit 1
}
say "Rust checkout $MR_REPO (HEAD $(git -C "$MR_REPO" rev-parse --short HEAD))"
if [ -n "$(git -C "$MR_REPO" status --porcelain --untracked-files=all | grep '^??' || true)" ]; then
  echo "WARNING: untracked files in the Rust repo — Nix cannot see them when"
  echo "         building from that repo directly (git fetcher = tracked +"
  echo "         staged only). \`git add\` any new source file. The deploy"
  echo "         below still sees them (a path input copies the whole tree):"
  git -C "$MR_REPO" status --porcelain --untracked-files=all | grep '^??' || true
fi

# --- 2. what is deployed now --------------------------------------------------
cd "$REPO_ROOT"
old="$(exec_start)"
say "currently declared: $old"

# --- 3./4. re-lock and compare ------------------------------------------------
say "re-locking the '$INPUT' path input"
nix flake update "$INPUT"
new="$(exec_start)"
say "after re-lock:       $new"

if [ "$old" = "$new" ] && [ "$FORCE" -eq 0 ]; then
  echo "$INPUT source is unchanged — nothing to deploy."
  echo "(re-run with --force to switch anyway)"
  exit 0
fi

if [ "$DO_REBUILD" -eq 0 ]; then
  echo "flake.lock updated; --no-rebuild so stopping here."
  exit 0
fi

# --- 5. switch ----------------------------------------------------------------
if [ "$(hostname)" != "$HOST" ]; then
  echo "ERROR: refusing to \`nixos-rebuild switch\` on $(hostname) — that would" >&2
  echo "       switch THIS machine, not $HOST. Re-run on $HOST (or pass" >&2
  echo "       --no-rebuild to only refresh flake.lock here)." >&2
  exit 1
fi

say "nixos-rebuild switch --flake ."
sudo nixos-rebuild switch --flake "$REPO_ROOT"

# --- 6. confirm (autoRollback would otherwise rebuild + reboot) ---------------
if command -v nixos-confirm > /dev/null 2>&1; then
  say "nixos-confirm"
  sudo nixos-confirm
else
  echo "WARNING: nixos-confirm not on PATH — confirm the generation manually!" >&2
fi

# --- 7. verify ----------------------------------------------------------------
say "verifying"
live="$(sed -n 's|^ExecStart=\(/nix/store/[^ ]*\)$|\1|p' /etc/systemd/system/meter-relay.service | head -1)"
printf 'unit ExecStart : %s\n' "$live"
printf 'service        : %s\n' "$(systemctl is-active meter-relay)"
if diff -q <(printf '%s' "$live") <(printf '%s' "$new") > /dev/null; then
  echo "✓ the unit runs the newly locked build"
else
  echo "✗ unit still points elsewhere — expected $new" >&2
  exit 1
fi

if curl -fsS --max-time 5 http://127.0.0.1:8484/api/status | head -c 120; then
  echo
  echo "✓ dashboard answering on :8484"
else
  echo "✗ dashboard did not answer on :8484" >&2
  exit 1
fi
