#!/run/current-system/sw/bin/bash
# Generic final sweep on the rendered watch copy: windows at seam points
# (cumulative from seg durations in $1/seg) + tail; on ALL-CLEAN removes
# $1/seg scratch (stitched master kept). Terminal markers.
set -uo pipefail
export PATH=/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin
FF=/nix/store/9qh7i54hk78czcdvxwd78q4i1idc9mc3-ffmpeg-9.0.2-bin/bin/ffmpeg
FP=$(sed -n "s|^FFPROBE=||p" $HOME/nixos-config/result/bin/footage-clean | tr -d "\"")
D="$1"; O="$2"; . "$D/conf"
W=${WORK:-$D}/seg
ok=1; i=$(ls "$W"/seg*.mkv 2>/dev/null | wc -l)
relchk() {
  local r
  r=$($FF -nostdin -v error -ss "$2" -t 2.8 -i "$1" -vf "signalstats,metadata=print:file=-" -an -f null - 2>/dev/null | awk -v lo="$3" -v hi="$4" '
      /pts_time/{match($0,/pts_time:[0-9.]+/);t=substr($0,RSTART+9,RLENGTH-9)}
      /UAVG/{split($0,c,"=");u=c[2]} /VAVG/{split($0,c,"=");v=c[2]} /YAVG/{split($0,b,"=");y=b[2]}
      /YDIF/{split($0,e,"=");yd=e[2]; d=u-v} /UDIF/{split($0,e,"=");ud=e[2]}
      /VDIF/{split($0,e,"=");vd=e[2]; m=yd; if(ud>m)m=ud; if(vd>m)m=vd
        if (t+0>=lo && t+0<=hi) {n++; if (d>80 && y<120) bl++; if (m>35) tr++}}
      END{if (bl) {print "BLUE " bl "/" n} else if (tr>1) print "TEAR " tr "/" n; else if (!n) print "SKIP"; else print "ok " n}')
  echo "  $5 : $r"
  case "$r" in ok*) ;; *) ok=0;; esac
}
cum=0
for k in $(seq 1 $((i-1))); do
  n=$(printf %02d $k)
  d=$($FP -v error -show_entries format=duration -of default=nw=1:nk=1 "$W/seg$n.mkv")
  cum=$(awk -v c="$cum" -v d="$d" 'BEGIN{printf "%.3f", c+d}')
  relchk "$O" $(awk "BEGIN{printf \"%.2f\", $cum-1.2}") 0.40 1.60 "seam $k @ $cum"
done
last=$($FP -v error -show_entries format=duration -of default=nw=1:nk=1 "$O")
relchk "$O" $(awk "BEGIN{printf \"%.2f\", $last-1.8}") 0.40 1.70 "tail @ $last"
if [ $ok -eq 1 ]; then
  rm -rf "$W"
  echo "ALL-CLEAN — scratch removed"
else
  echo "SWEEP-PROBLEM — scratch kept"
fi
echo "FINAL-DONE"
