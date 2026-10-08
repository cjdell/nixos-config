#!/usr/bin/env bash
# Record a timeline marker so a capture can be sliced by what was happening.
#   ./mark.sh <name> "started VirtualDub capture"
cd "$(dirname "$0")"
NAME=${1:?name}; shift
echo "$(date +%s)  $(date '+%H:%M:%S')  $*" | tee -a "logs/timeline-$NAME.txt"
