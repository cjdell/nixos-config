#!/run/current-system/sw/bin/bash
# Generic stitch driver for batch tapes. Input: $1 = working dir containing
#   conf: SRC_<tag>=<path> lines, OUT=<stitched path>, optional OSD= rect
#   cuts: <tag> <ss> <to>  (tab/space separated, concat order)
# Does: per-edge deep gate (relative-pts, 0.4s, thresh d>45) -> cuts on NFS
# -> sum-probed-duration assert -> seam check on stitched -> STITCH2-OK /
# *_FAIL markers. No render here.
set -uo pipefail
export PATH=/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin
FF=/nix/store/9qh7i54hk78czcdvxwd78q4i1idc9mc3-ffmpeg-9.0.2-bin/bin/ffmpeg
FP=$(sed -n "s|^FFPROBE=||p" $HOME/nixos-config/result/bin/footage-clean | tr -d "\"")
D="$1"; . "$D/conf"
W=${WORK:-$D}/seg; mkdir -p "$W"
OUT="$STITCHED"
ok=1; ns=0
relchk() { # src seek lo hi name
  local r
  r=$($FF -nostdin -v error -ss "$2" -t $(awk "BEGIN{printf \"%.2f\", $4+0.5}") -i "$1" \
      -vf "signalstats,metadata=print:file=-" -an -f null - 2>/dev/null | awk -v lo="$3" -v hi="$4" '
      /pts_time/{match($0,/pts_time:[0-9.]+/);t=substr($0,RSTART+9,RLENGTH-9)}
      /UAVG/{split($0,c,"=");u=c[2]} /VAVG/{split($0,c,"=");v=c[2]} /YAVG/{split($0,b,"=");y=b[2]}
      /YDIF/{d=u-v; if (t+0>=lo && t+0<=hi) {n++; if (d>80 && y<120) bl++}}
      END{if (bl) {print "BLUE " n} else if (!n) print "SKIP"; else print "ok " n}')
  echo "  $5 : $r"
  case "$r" in ok*) ;; *) ok=0;; esac
}
mapfile -t CUTS < "$D/cuts"
for row in "${CUTS[@]}"; do
  read -r tag ss to <<< "$row"
  [ -z "${tag:-}" ] && continue
  eval "src=\$SRC_$tag"
  ns=$((ns+1))
  relchk "$src" $(awk "BEGIN{printf \"%.2f\", $ss-0.30}") 0.32 0.70 "edge ${tag} [$ss st]"
  relchk "$src" $(awk "BEGIN{printf \"%.2f\", $to-0.90}") 0.55 0.90 "edge ${tag} [$to en]"
done
if [ $ok -eq 0 ]; then echo "DRIVER-FAIL edges"; exit 1; fi
echo "$(date +%T) cutting $ns segments"
i=0
for row in "${CUTS[@]}"; do
  read -r tag ss to <<< "$row"
  [ -z "${tag:-}" ] && continue
  eval "src=\$SRC_$tag"
  i=$((i+1)); n=$(printf %02d $i)
  $FF -nostdin -v error -y -ss "$ss" -to "$to" -i "$src" -c copy -avoid_negative_ts make_zero "$W/seg$n.mkv" || { echo "DRIVER-FAIL cut$n"; exit 1; }
done
sum=0
for k in $(seq 1 $i); do
  n=$(printf %02d $k)
  d=$($FP -v error -show_entries format=duration -of default=nw=1:nk=1 "$W/seg$n.mkv")
  sum=$(awk -v s="$sum" -v d="$d" 'BEGIN{print s+d}')
done
echo "sum-of-segments: $sum"
{ for k in $(seq 1 $i); do n=$(printf %02d $k); printf "file '%s'\n" "$W/seg$n.mkv"; done; } > "$W/list.txt"
echo "$(date +%T) concat"
$FF -nostdin -v error -y -f concat -safe 0 -i "$W/list.txt" -c copy -avoid_negative_ts make_zero "$OUT"
rc=$?
tot=$($FP -v error -show_entries format=duration,size -of csv=p=0 "$OUT")
echo "total: $tot rc=$rc"
g=$(awk -v s="$sum" -v T="$tot" 'BEGIN{split(T,a,","); d=a[1]; print (d>s-0.5 && d<s+0.5) ? "1" : "0"}')
[ "$g" = 1 ] && echo "STITCH-OK dur=$tot" || echo "DRIVER-FAIL dur=$tot sum=$sum"
echo "== seams =="
cum=0
for k in $(seq 1 $((i-1))); do
  n=$(printf %02d $k)
  d=$($FP -v error -show_entries format=duration -of default=nw=1:nk=1 "$W/seg$n.mkv")
  cum=$(awk -v c="$cum" -v d="$d" 'BEGIN{printf "%.3f", c+d}')
  relchk "$OUT" $(awk "BEGIN{printf \"%.2f\", $cum-0.6}") 0.24 0.96 "seam $k @ $cum"
done
last=$(awk -v T="$tot" 'BEGIN{split(T,a,","); print a[1]}')
relchk "$OUT" $(awk "BEGIN{printf \"%.2f\", $last-1.3}") 0.30 1.20 "tail @ $last"
if [ $ok -eq 1 ]; then echo "DRIVER-READY"; else echo "DRIVER-FAIL seams"; fi
echo "DRIVER-DONE"
