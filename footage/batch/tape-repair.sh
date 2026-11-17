#!/run/current-system/sw/bin/bash
# D4 seam repair: sweep caught the dropout onset-flash/recovery-dip leaking
# ~1-2 frames into seg1/seg2 tails around seams 1-2 (YDIF 37-57 vs floor 4-8).
# Re-cut segments 1-3 with wider excision margins, re-render just those wsegs,
# re-concat all 8, re-sweep. F@H parked for the render only.
set -uo pipefail
export PATH=/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin
FF=/nix/store/9qh7i54hk78czcdvxwd78q4i1idc9mc3-ffmpeg-9.0.2-bin/bin/ffmpeg
FP=$(sed -n "s|^FFPROBE=||p" $HOME/nixos-config/result/bin/footage-clean | tr -d "\"")
KIT=$HOME/nixos-config/result/bin/footage-clean
SUDO=/run/wrappers/bin/sudo
D=$HOME/b/D4; . $D/conf
W=$WORK/seg
ARGS=(--deint auto --denoise none --codec nvenc-hevc --crf 16 --preset slow
      --single-pass --source-color --me-search 5 --me-searchparam 3
      --me-range 32 --me-divide --me-rblk 16 --deint-degrain 0)
echo "$(date +%F_%T) REPAIR-START"
ok=1
cut() { # num ss to
  $FF -nostdin -v error -y -ss "$2" -to "$3" -i "$SRC_D4" -c copy -avoid_negative_ts make_zero "$W/seg$1.mkv" || { echo "CUTFAIL $1"; ok=0; }
  d=$($FP -v error -show_entries format=duration -of default=nw=1:nk=1 "$W/seg$1.mkv")
  dev=$(awk -v d="$d" -v e="$3" -v s="$2" 'BEGIN{x=d-(e-s); printf "%.3f",(x<0)?-x:x}')
  echo "  recut seg$1 probed=$d dev=$dev"
  awk -v x="$dev" 'BEGIN{exit !(x<=0.30)}' || { echo "DURFAIL seg$1"; ok=0; }
}
cut 01 1.200 321.950
cut 02 325.100 649.500
cut 03 654.900 709.960
[ $ok = 1 ] || { echo REPAIR-DONE; exit 1; }
$SUDO -n systemctl stop fah-client
for n in 01 02 03; do
  echo "$(date +%F_%T) render wseg$n"
  if ! "$KIT" "${ARGS[@]}" "$W/seg$n.mkv" "$W/wseg${n#0}.mkv" > "$W/rlog$n.txt" 2>&1; then
    echo "SEGFAIL $n"; tail -3 "$W/rlog$n.txt"; ok=0; break
  fi
done
$SUDO -n systemctl start fah-client && echo "$(date +%F_%T) fah restarted"
[ $ok = 1 ] || { echo REPAIR-DONE; exit 1; }
{ for k in $(seq 1 8); do printf "file '%s'\n" "$W/wseg$k.mkv"; done; } > "$W/wlist.txt"
$FF -nostdin -v error -y -f concat -safe 0 -i "$W/wlist.txt" -c copy -avoid_negative_ts make_zero "$WATCH" || ok=0
echo "$(date +%F_%T) concat rc=$ok"
bash $HOME/tape-final.sh "$D" "$WATCH"
echo "$(date +%F_%T) REPAIR-DONE"
