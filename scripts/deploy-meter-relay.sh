#!/usr/bin/env bash
# deploy-meter-relay.sh — deploy the crates/meter-relay-rs crate to grafton-router.
#
# meter-relay-rs now lives IN this repo (crates/meter-relay-rs) and is built by
# the root flake: hosts/grafton-router/services/meter-relay.nix calls its
# nix/package.nix with this repo's nixpkgs + the `crane` input. There is no path
# input and no separate flake.lock entry to refresh any more — editing the crate
# and rebuilding is the whole loop.
#
# The one trap that remains is that Nix reads this repo through the *git*
# fetcher: tracked files (modified or not) and staged files are visible, but a
# file that is merely untracked is NOT. A new .rs/.tsx/.nix file must therefore
# be `git add`ed (staging is enough) or the build fails on a file that is
# plainly in the working tree.
#
#   1. sanity-check the crate checkout (warn about untracked NEW files)
#   2. note the currently-deployed store path (from the live unit)
#   3. evaluate the new store path from the working tree
#   4. stop if it did not change (--force to switch anyway)
#   5. sudo nixos-rebuild switch --flake .
#   6. sudo nixos-confirm — grafton-router has autoRollback (see AGENTS.md)!
#   7. verify the unit runs the new path and the dashboard answers on :8484
#
# Usage: ./scripts/deploy-meter-relay.sh [options]
#   --no-rebuild   evaluate and report only; do not switch anything
#   --force        switch even when the store path did not change
#   -h|--help      show this help
#
# Run WITHOUT sudo (sudo is used internally for the rebuild + confirm), from
# this repo's checkout ON grafton-router. A switch only affects the machine it
# runs on, so the script refuses to rebuild anywhere else (--no-rebuild still
# works there).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

CRATE="$REPO_ROOT/crates/meter-relay-rs"
HOST="grafton-router"
EXEC_START_ATTR=".#nixosConfigurations.${HOST}.config.systemd.services.meter-relay.serviceConfig.ExecStart"

DO_REBUILD=1
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --no-rebuild) DO_REBUILD=0 ;;
    --force) FORCE=1 ;;
    -h | --help)
      sed -n '2,36p' "${BASH_SOURCE[0]}"
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

# The path the currently-deployed unit runs (empty if the unit is absent, e.g.
# on a machine that is not grafton-router).
deployed_path() {
  [ -e /etc/systemd/system/meter-relay.service ] || return 0
  sed -n 's|^ExecStart=\(/nix/store/[^ ]*\)$|\1|p' /etc/systemd/system/meter-relay.service | head -1
}

# --- 1. the crate checkout ----------------------------------------------------
[ -d "$CRATE/src" ] || {
  echo "ERROR: $CRATE does not look like the meter-relay-rs crate" >&2
  exit 1
}
say "crate $CRATE"
if [ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=all -- "$CRATE" | grep '^??' || true)" ]; then
  echo "WARNING: untracked files in the crate — Nix cannot see them (the flake"
  echo "         is read through the git fetcher = tracked + staged only)."
  echo "         \`git add\` any new source file:"
  git -C "$REPO_ROOT" status --porcelain --untracked-files=all -- "$CRATE" | grep '^??' || true
fi

# --- 2. what is deployed now --------------------------------------------------
cd "$REPO_ROOT"
old="$(deployed_path)"
if [ -n "$old" ]; then
  say "currently deployed: $old"
else
  say "no live unit found (nothing deployed yet / not on $HOST)"
fi

# --- 3./4. evaluate the working tree and compare ------------------------------
new="$(exec_start)"
say "from working tree:  $new"

if [ -n "$old" ] && [ "$old" = "$new" ] && [ "$FORCE" -eq 0 ]; then
  echo "meter-relay-rs build is unchanged — nothing to deploy."
  echo "(re-run with --force to switch anyway)"
  exit 0
fi

if [ "$DO_REBUILD" -eq 0 ]; then
  echo "--no-rebuild so stopping here."
  exit 0
fi

# --- 5. switch ----------------------------------------------------------------
if [ "$(hostname)" != "$HOST" ]; then
  echo "ERROR: refusing to \`nixos-rebuild switch\` on $(hostname) — that would" >&2
  echo "       switch THIS machine, not $HOST. Re-run on $HOST (or pass" >&2
  echo "       --no-rebuild to only report here)." >&2
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
live="$(deployed_path)"
printf 'unit ExecStart : %s\n' "$live"
printf 'service        : %s\n' "$(systemctl is-active meter-relay)"
if [ "$live" = "$new" ]; then
  echo "✓ the unit runs the newly built crate"
else
  echo "✗ unit still points elsewhere — expected $new" >&2
  exit 1
fi

# Startup discovery listens on the serial endpoints for a few seconds before
# anything is served, so the dashboard is *expected* to be silent for the first
# ~3 s after activation. Poll for it rather than treating that window as a
# failed deploy.
dashboard=""
for _ in $(seq 1 20); do
  if dashboard="$(curl -fsS --max-time 5 http://127.0.0.1:8484/api/status 2>/dev/null)"; then
    break
  fi
  sleep 1
done

if [ -n "$dashboard" ]; then
  printf '%s\n' "$dashboard" | head -c 120
  echo
  echo "✓ dashboard answering on :8484"
  if curl -fsS --max-time 5 http://127.0.0.1:8484/api/connections >/dev/null; then
    echo "✓ /api/connections answering (see the dashboard's /#/diagnostics page)"
  else
    echo "✗ /api/connections did not answer" >&2
    exit 1
  fi
else
  echo "✗ dashboard did not answer on :8484 within 20 s" >&2
  exit 1
fi
