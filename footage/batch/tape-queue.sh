#!/run/current-system/sw/bin/bash
# Tape QUEUE: runs the remaining pipeline per tape: [stitch driver] ->
# render -> final sweep. Direct-render tapes (single TO trim) get a strict
# full-fps edge gate on the trim point instead of a stitch. Per-tape
# RESULT_<key> lines; independent failures; QUEUE-DONE terminal.
# Confs: $1=<tape dir>: conf(SRC_*,WATCH,STITCHED,OSDARG,[TO]) + cuts (stitch)
set -uo pipefail
export PATH=/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin
FF=/nix/store/9qh7i54hk78czcdvxwd78q4i1idc9mc3-ffmpeg-9.0.2-bin/bin/ffmpeg
B=$HOME/b
SUDO=/run/wrappers/bin/sudo
declare -A RES
gate_to() { # src to — strict full-fps window decode ending at the trim
  local r
  r=$($FF -nostdin -v error -ss $(awk "BEGIN{printf \"%.2f\", $2-0.90}") -t 1.3 -i "$1" \
      -vf "signalstats,metadata=print:file=-" -an -f null - 2>/dev/null | awk -v lo=0.55 -v hi=0.90 '
      /pts_time/{match($0,/pts_time:[0-9.]+/);t=substr($0,RSTART+9,RLENGTH-9)}
      /UAVG/{split($0,c,"=");u=c[2]} /VAVG/{split($0,c,"=");v=c[2]} /YAVG/{split($0,b,"=");y=b[2]}
      /YDIF/{d=u-v; if (t+0>=lo && t+0<=hi) {n++; if (d>80 && y<120) bl++}}
      END{if (bl) {print "BLUE " bl "/" n} else if (!n) print "SKIP"; else print "ok " n}')
  echo "  gate_to: $r"
  case "$r" in ok*) return 0;; *) return 1;; esac
}
run_tape() { # dir
  local D="$1" key rc
  key=$(basename "$D")
  local WATCH STITCHED OSDARG TO=""
  . "$D/conf"
  echo "==== $(date +%T) TAPE-START $key"
  if [ -n "${TO:-}" ]; then
    gate_to "$IN" "$TO" || { echo "RESULT_$key=GATEFAIL"; RES[$key]=GATEFAIL; return; }
  else
    bash $HOME/tape-driver.sh "$D" > "$D/driver.log" 2>&1
    rc=$?
    grep -q "DRIVER-READY" "$D/driver.log" || { echo "RESULT_$key=DRIVERFAIL"; RES[$key]=DRIVERFAIL; tail -8 "$D/driver.log"; return; }
    local IN="$STITCHED"
  fi
  bash $HOME/tape-render.sh "$IN" "$WATCH" "${OSDARG:-}" "${TO:-}" > "$D/render.log" 2>&1
  if ! grep -q " DONE " <(tail -c 2000 "$D/render.log" | tr "\r" "\n"); then
    echo "RESULT_$key=RENDERFAIL"; RES[$key]=RENDERFAIL; tail -4 "$D/render.log"; return
  fi
  bash $HOME/tape-final.sh "$D" "$WATCH" > "$D/final.log" 2>&1
  if grep -q "ALL-CLEAN" "$D/final.log"; then
    echo "RESULT_$key=OK"; RES[$key]=OK
  else
    echo "RESULT_$key=SWEEPROBLEM"; RES[$key]=SWEEPROBLEM; grep -E "BLUE|SKIP" "$D/final.log" | head -8
  fi
  echo "==== $(date +%T) TAPE-END $key"
}
for d in "$@"; do run_tape "$B/$d"; done
echo "QUEUE-SUMMARY ${RES[*]}"
echo "QUEUE-DONE"
