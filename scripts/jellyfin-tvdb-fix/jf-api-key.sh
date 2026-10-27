#!/usr/bin/env bash
# jf-api-key.sh — create/delete a temporary Jellyfin API key directly in the
# live jellyfin.db (no UI/login needed). Used by the other jf-* scripts.
#
# Usage:
#   JF_API_KEY=$(./jf-api-key.sh create my-temp-key)   # prints key to stdout
#   ./jf-api-key.sh delete my-temp-key
#
# Env:
#   JF_DB  path to jellyfin.db (default: /srv/jellyfin/config/data/data/jellyfin.db
#          on N100-NAS, the podman quadlet jellyfin)
#
# Notes:
#   * Writes through sudo (the DB is owned by the container user).
#   * The key takes effect immediately; no restart needed.
#   * ALWAYS delete the key when done:  ./jf-api-key.sh delete <name>
set -euo pipefail

JF_DB="${JF_DB:-/srv/jellyfin/config/data/data/jellyfin.db}"
SQL() { sudo nix shell nixpkgs#sqlite -c sqlite3 "$JF_DB" "$@"; }

case "${1:-}" in
  create)
    name="${2:?usage: jf-api-key.sh create <name>}"
    key="$(cat /proc/sys/kernel/random/uuid | tr -d '-')"
    SQL "INSERT INTO ApiKeys (DateCreated, DateLastActivity, Name, AccessToken) \
         VALUES (datetime('now'), datetime('now'), '${name}', '${key}');"
    echo "$key"
    >&2 echo "created key '${name}'; remember: $0 delete ${name}"
    ;;
  delete)
    name="${2:?usage: jf-api-key.sh delete <name>}"
    SQL "DELETE FROM ApiKeys WHERE Name='${name}';"
    >&2 echo "deleted key '${name}'"
    ;;
  list)
    SQL -column -header "SELECT Name, DateCreated FROM ApiKeys ORDER BY Id;"
    ;;
  *)
    echo "usage: $0 {create <name>|delete <name>|list}" >&2
    exit 2
    ;;
esac
