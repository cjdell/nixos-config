#!/usr/bin/env bash
# scrape-tvdb-season.sh — dump the LIVE TheTVDB episode numbering for one
# season as TSV:  SxxEyy <TAB> tvdb_episode_id <TAB> title
#
# Usage:
#   ./scrape-tvdb-season.sh <series-slug> <season> [season ...] > live.tsv
#   # e.g.  ./scrape-tvdb-season.sh star-trek-deep-space-nine 1 4 7 > /tmp/live.tsv
#
# The slug is the part of https://thetvdb.com/series/<slug>/seasons/official/N
# (search TheTVDB for the show). Repeat the season argument for several seasons.
#
# Why: provider numbering shifts under a stable show (TheTVDB re-edits season
# orders; e.g. DS9 S01/S04/S07 were renumbered on 2026-10-07 when "Emissary"
# and "The Way of the Warrior" were split into (1)/(2)). Anything matched
# before such an edit is off-by-N in Jellyfin; this TSV is the ground truth
# that jf-rematch.py re-applies.
set -euo pipefail

slug="${1:?usage: scrape-tvdb-season.sh <series-slug> <season> [season ...]}"
shift
[ $# -ge 1 ] || { echo "give at least one season number" >&2; exit 2; }

for s in "$@"; do
  s2=$(printf '%02d' "$s")
  curl -sL -A 'Mozilla/5.0 (X11; Linux x86_64)' \
    "https://thetvdb.com/series/${slug}/seasons/official/${s}" \
  | tr -d '\n' \
  | grep -oE "<td>S${s2}E[0-9]+</td>[[:space:]]*<td>[[:space:]]*<a href=\"/series/${slug}/episodes/[0-9]+\">[[:space:]]*[^<]+" \
  | sed -E "s|<td>(S[0-9]+E[0-9]+)</td>[[:space:]]*<td>[[:space:]]*<a href=\"/series/${slug}/episodes/([0-9]+)\">[[:space:]]*|\1\t\2\t|" \
  | sed -E 's/[[:space:]]+$//'
done
