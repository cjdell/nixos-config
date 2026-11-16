#!/run/current-system/sw/bin/bash
# Per-segment render: $1 = segment dir ($WORK/seg)  $2 = watch out
# $3 = osd-rect (""). Each cut segment is rendered by the kit SEPARATELY,
# then the HEVC/PCM results are stream-copy concatenated. This exists
# because the kit's temporal filters (qtgmc ME) running over one big
# stitched file see across every concat boundary: motion estimators fail
# at the artificial jump and ghost/streak 2-4 output frames on the seam
# even when the cut files are provably clean. Per-segment, each tail
# clamps at its own end; no filter ever sees the far side of a gap.
# Bonus: no lavf pre-index (segments are short). F@H parked once.
set -uo pipefail
export PATH=/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin
FF=/nix/store/9qh7i54hk78czcdvxwd78q4i1idc9mc3-ffmpeg-9.0.2-bin/bin/ffmpeg
KIT=$HOME/nixos-config/result/bin/footage-clean
FP=$(sed -n "s|^FFPROBE=||p" $HOME/nixos-config/result/bin/footage-clean | tr -d "\"")
SUDO=/run/wrappers/bin/sudo
W="$1"; OUT="$2"; OSD="${3:-}"
mapfile -t SEGS < <(ls "$W"/seg*.mkv 2>/dev/null | sort)
n=${#SEGS[@]}
[ $n -ge 1 ] || { echo "FAIL no segments"; exit 1; }
echo "$(date +%F_%T) stopping fah-client"
$SUDO -n systemctl stop fah-client
ARGS=(--deint auto --denoise none --codec nvenc-hevc --crf 16 --preset slow
      --single-pass --source-color --me-search 5 --me-searchparam 3
      --me-range 32 --me-divide --me-rblk 16 --deint-degrain 0)
[ -n "$OSD" ] && ARGS+=(--osd-rect "$OSD")
ok=1; sum=0; i=0
for s in "${SEGS[@]}"; do
  i=$((i+1)); o="$W/wseg$i.mkv"
  echo "$(date +%F_%T) render seg $i/$n $(basename "$s")"
  if ! "$KIT" "${ARGS[@]}" "$s" "$o" > "$W/rlog$i.txt" 2>&1; then
    echo "SEGFAIL $i"; tail -3 "$W/rlog$i.txt"; ok=0; break
  fi
  d=$($FP -v error -show_entries format=duration -of default=nw=1:nk=1 "$o")
  sum=$(awk -v a="$sum" -v b="$d" 'BEGIN{printf "%.3f", a+b}')
  echo "  seg$i dur=$d sum=$sum"
done
if [ $ok = 1 ]; then
  { for k in $(seq 1 $n); do printf "file '%s'\n" "$W/wseg$k.mkv"; done; } > "$W/wlist.txt"
  $FF -nostdin -v error -y -f concat -safe 0 -i "$W/wlist.txt" -c copy -avoid_negative_ts make_zero "$OUT" || ok=0
fi
$SUDO -n systemctl start fah-client && echo "$(date +%F_%T) fah-client restarted"
if [ $ok = 1 ]; then
  tot=$($FP -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT")
  g=$(awk -v s="$sum" -v t="$tot" -v n="$n" 'BEGIN{d=t-s; if(d<0)d=-d; print (d < 0.1+0.1*n) ? 1 : 0}')
  if [ "$g" = 1 ]; then echo "$(date +%F_%T) DONE $(du -h "$OUT" | cut -f1) dur=$tot sum=$sum"
  else echo "$(date +%F_%T) FAIL dur-mismatch tot=$tot sum=$sum"; ok=0; fi
else
  echo "$(date +%F_%T) FAIL"
fi
[ $ok = 1 ] && exit 0 || exit 1
