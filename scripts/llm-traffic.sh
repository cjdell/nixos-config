#!/usr/bin/env bash
# Show where LLM API requests come from.
#
# Reads the nginx access log (the one place every LLM client is visible: the
# container, the Pi over the tailnet, agents on this box, plain curl) and labels
# each request by caller. Strata's own log (/var/lib/strata/strata.log) has the
# per-request engine stats but NO client identity, so nginx is the source of
# truth for "who asked".
#
# usage:
#   ./scripts/llm-traffic.sh            # last 30 min, grouped summary
#   ./scripts/llm-traffic.sh -n 120     # last 120 min
#   ./scripts/llm-traffic.sh -f         # follow live (one line per request)
#
# Notes:
#   * nginx logs IP + User-Agent + path, NOT max_tokens. The 2000-token calls
#     are Recallium's insight pipeline (container 10.88.0.3, "AsyncOpenAI/Python");
#     cross-check a live request with:
#       sudo journalctl -u strata -f | grep 'max_tokens'
#   * requests that bypass nginx (gpu-mode's warm-up, the supervisor plugin's
#     LFM3 judge on 127.0.0.1:8086) do not appear here.
set -euo pipefail

LOGFILE=${LOGFILE:-/var/log/nginx/access.log}
MINUTES=30
FOLLOW=0

while [ $# -gt 0 ]; do
  case "$1" in
    -f|--follow) FOLLOW=1 ;;
    -n|--minutes) MINUTES=${2:?}; shift ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (try -h)" >&2; exit 2 ;;
  esac
  shift
done

# awk program shared by both modes -------------------------------------------------
# Combined log format:
#   IP - - [17/Nov/2026:02:08:51 +0000] "POST /v1/chat/completions HTTP/1.1" 200 1234 "-" "UA"
AWK_COMMON='
BEGIN {
  split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", mn, " ")
  for (i = 1; i <= 12; i++) mon[mn[i]] = i
}
function to_epoch(t,   m) {
  # t like 17/Nov/2026:02:08:51
  split(t, p, /[\/:]/)
  return mktime(p[3] " " sprintf("%02d", mon[p[2]]) " " p[1] " " p[4] " " p[5] " " p[6], 1)
}
function label(ua) {
  if (ua ~ /^AsyncOpenAI/)  return "recallium"
  if (ua ~ /^opencode/)     return "opencode"
  if (ua ~ /^pi\//)         return "pi"
  if (ua ~ /^curl\//)       return "curl"
  if (ua ~ /Mozilla|Safari|Chrome|Firefox/) return "browser"
  if (ua == "-")            return "no-ua"
  return "other"
}
# Only the endpoints that land on an LLM engine.
function is_llm(path) {
  return path ~ /^\/(v1\/(chat\/completions|completions|models)|recallium-llm\/|lfm3\/|lfm3$|strata\/|llm\/)/
}
'

if [ "$FOLLOW" = 1 ]; then
  echo "following $LOGFILE (LLM endpoints only, Ctrl-C to stop)" >&2
  sudo -n tail -F -n 0 "$LOGFILE" 2>/dev/null | gawk "$AWK_COMMON"'
  {
    if (match($0, /\[[0-9]{2}\/[A-Za-z]{3}\/[0-9]{4}:[0-9]{2}:[0-9]{2}:[0-9]{2} \+0000\]/)) {
      ts = substr($0, RSTART + 1, RLENGTH - 2)
    } else { next }
    split($0, q, "\"")
    split(q[2], r, " ")
    path = r[2]
    if (!is_llm(path)) next
    ua = q[6]
    printf "%s  %-10s %-24s %-34s %s\n", substr(ts, 13, 8), label(ua), $1, ua, r[1] " " path
  }'
  exit 0
fi

CUTOFF=$(( $(date -u +%s) - MINUTES * 60 ))
echo "LLM API traffic, last ${MINUTES} min ($(date -u '+%H:%M:%S') UTC), from $LOGFILE"
echo

sudo -n tail -n 200000 "$LOGFILE" 2>/dev/null | gawk -v cutoff="$CUTOFF" "$AWK_COMMON"'
{
  if (!match($0, /\[[0-9]{2}\/[A-Za-z]{3}\/[0-9]{4}:[0-9]{2}:[0-9]{2}:[0-9]{2} \+0000\]/)) next
  ts = substr($0, RSTART + 1, RLENGTH - 2)
  t = to_epoch(ts)
  if (t < cutoff) next
  split($0, q, "\""); split(q[2], r, " ")
  path = r[2]
  if (!is_llm(path)) next
  ua = q[6]; ip = $1
  key = label(ua) "|" ip "|" r[1] " " path
  n[key]++
  if (!(key in first)) first[key] = substr(ts, 13, 8)
  last[key] = substr(ts, 13, 8)
}
END {
  for (k in n) {
    split(k, f, "|")
    printf "%d|%s|%s|%s|%s|%s\n", n[k], f[1], f[2], first[k], f[3], last[k]
  }
}' | sort -t'|' -k1,1nr | gawk -F'|' '
BEGIN {
  if (0) exit
  printf "  %5s  %-10s %-40s %-9s %-36s %s\n", "count", "source", "client", "first", "path", "last"
  printf "  %5s  %-10s %-40s %-9s %-36s %s\n", "-----", "------", "------", "-----", "----", "----"
}
{ printf "  %5d  %-10s %-40s %-9s %-36s %s\n", $1, $2, $3, $4, $5, $6 }'

echo
echo "labels: recallium=container (insight/enrichment jobs, max_tokens=2000)  opencode=agent on this box"
echo "        pi=pi agent over tailnet/hackspace  curl=scripts/probes  browser=UI polling /v1/models"
