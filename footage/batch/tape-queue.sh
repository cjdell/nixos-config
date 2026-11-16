#!/run/current-system/sw/bin/bash
# Tape QUEUE v2. Args: tape dirs (under ~/b). conf keys:
#   STITCHED WATCH OSDARG [TO for direct-render tapes] [PERSEG=1] WORK
# Flow per tape:
#   direct (TO set):   gate_to -> tape-render.sh (IN/TO from conf)
#   stitch (default):  tape-driver.sh (gate->cut->concat->seam-check)
#                      -> PERSEG? tape-render-segs.sh (each seg rendered
#                         alone; qtgmc never sees across a cut) : tape-render.sh
#                      -> tape-final.sh (sweep + cleanup on ALL-CLEAN)
# Per-tape RESULT_<key> markers; failures don't stop the queue; QUEUE-DONE.
set -uo pipefail
export PATH=/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin
FF=/nix/store/9qh7i54hk78czcdvxwd78q4i1idc9mc3-ffmpeg-9.0.2-bin/bin/ffmpeg
B=$HOME/b
SUDO=/run/wrappers/bin/sudo
declare -A RES
gate_to() { # src to
  local r
  r=$($FF -nostdin -v error -ss $(awk "BEGIN{printf \"%.2f\", $2-0.90}") -t 1.3 -i "$1" \
      -vf "signalstats,metadata=print:file=-" -an -f null - 2>/dev/null | awk -v lo=0.55 -v hi=0.90 '
      /pts_time/{match($0,/pts_time:[0-9.]+/);t=substr($0,RSTART+9,RLENGTH-9)}
      /UAVG/{split($0,c,"=");u=c[2]} /VAVG/{split($0,c,"=");v=c[2]} /YAVG/{split($0,b,"=");y=b[2]}
      /YDIF/{split($0,e,"=");yd=e[2]} /UDIF/{split($0,e,"=");ud=e[2]} /VDIF/{split($0,e,"=");vd=e[2];
        m=yd; if(ud>m)m=ud; if(vd>m)m=vd
        if (t+0>=lo && t+0<=hi) {n++; if (d>80 && y<120) bl++; if (m>35) tr++}}
      END{if (bl) {print "BLUE " bl "/" n} else if (tr>1) print "TEAR " tr "/" n; else if (!n) print "SKIP"; else print "ok " n}')
  echo "  gate_to: $r"
  case "$r" in ok*) return 0;; *) return 1;; esac
}
run_tape() { # dir
  local D="$1" key rc IN
  key=$(basename "$D")
  local WATCH STITCHED OSDARG TO="" PERSEG="" WORK
  . "$D/conf"
  echo "==== $(date +%T) TAPE-START $key"
  if [ -n "${TO:-}" ]; then
    IN=$(sed -n 's/^IN=//p' "$D/conf" | head -1 | tr -d '"')
    gate_to "$IN" "$TO" || { echo "RESULT_$key=GATEFAIL"; RES[$key]=GATEFAIL; return; }
    bash $HOME/tape-render.sh "$IN" "$WATCH" "${OSDARG:-}" "$TO" > "$D/render.log" 2>&1
  else
    bash $HOME/tape-driver.sh "$D" > "$D/driver.log" 2>&1
    grep -q "DRIVER-READY" "$D/driver.log" || { echo "RESULT_$key=DRIVERFAIL"; RES[$key]=DRIVERFAIL; tail -8 "$D/driver.log"; return; }
    if [ -n "${PERSEG:-}" ]; then
      bash $HOME/tape-render-segs.sh "$WORK/seg" "$WATCH" "${OSDARG:-}" > "$D/render.log" 2>&1
    else
      bash $HOME/tape-render.sh "$STITCHED" "$WATCH" "${OSDARG:-}" "" > "$D/render.log" 2>&1
    fi
  fi
  if ! grep -q " DONE " <(tail -c 2000 "$D/render.log" | tr "\r" "\n"); then
    echo "RESULT_$key=RENDERFAIL"; RES[$key]=RENDERFAIL; tail -4 "$D/render.log"; return
  fi
  bash $HOME/tape-final.sh "$D" "$WATCH" > "$D/final.log" 2>&1
  if grep -q "ALL-CLEAN" "$D/final.log"; then
    echo "RESULT_$key=OK"; RES[$key]=OK
  else
    echo "RESULT_$key=SWEEPROBLEM"; RES[$key]=SWEEPROBLEM; grep -E "BLUE|SKIP|TEAR" "$D/final.log" | head -8
  fi
  echo "==== $(date +%T) TAPE-END $key"
}
for d in "$@"; do run_tape "$B/$d"; done
echo "QUEUE-SUMMARY ${RES[*]}"
echo "QUEUE-DONE"
