#!/run/current-system/sw/bin/bash
# Generic stitch/cut driver for batch tapes. Input: $1 = working dir containing
#   conf: SRC_<tag>=<path> lines, STITCHED=<stitched path>, WORK,
#         optional OSDARG, PERSEG=1, SKIPCONCAT=1
#   cuts: <tag> <ss> <to>  (tab/space separated, concat order)
# Does: per-edge deep gate (relative-pts, 0.4s, strict-blue) -> cuts on NFS
# -> PER-SEGMENT DURATION ASSERT (probed duration vs to-ss, >0.30s = the
#    source's packet timestamps or the input seek lie at that spot — refuse
#    to render) -> concat + seam check -> STITCH-OK / DRIVER-READY.
# SKIPCONCAT=1 (single-file tapes rendered per segment): stops after the
#   duration assert — the raw concat is identical content and the final
#   sweep verifies seams on the RENDERED watch copy anyway. No 119 GB of
#   NFS written for nothing.
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
  d=$($FP -v error -show_entries format=duration -of default=nw=1:nk=1 "$W/seg$n.mkv")
  dev=$(awk -v d="$d" -v e="$to" -v s="$ss" 'BEGIN{x=d-(e-s); printf "%.3f",(x<0)?-x:x}')
  echo "  seg$n probed=$d expected=$(awk -v e="$to" -v s="$ss" 'BEGIN{printf "%.3f",e-s}') dev=$dev"
  awk -v x="$dev" 'BEGIN{exit !(x<=0.30)}' || { echo "DRIVER-FAIL seg$n duration dev $dev (seek/ts drift)"; exit 1; }
done
echo "$(date +%T) cuts verified"
if [ "${SKIPCONCAT:-0}" = 1 ]; then
  echo "SKIPCONCAT: no stitched rebuild (per-seg render mode)"
  echo "DRIVER-READY"
  echo "DRIVER-DONE"
  exit 0
fi
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
