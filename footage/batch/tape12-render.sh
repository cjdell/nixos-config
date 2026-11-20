#!/run/current-system/sw/bin/bash
# Dell Tape 12 mixed-source render. $1 = EDL tsv (class src from len o0 o1 bl)
# $2 = workdir  $3 = output mkv. NEW rows render from the 2026 PCTV masters
# (part table = ~/b12aud/index.txt), OLD rows from the 2004 NVECapture files.
# Every segment: kit per-seg render (in-source --from/--to trim), then audio
# normalized to PCM s16le so the stream-copy concat is uniform (old sources
# carry mp2). Duration-asserts per segment and at the end; F@H parked around
# the whole run. Terminal marker: DONE/FAIL.
set -uo pipefail
export PATH=/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin
FF=/nix/store/9qh7i54hk78czcdvxwd78q4i1idc9mc3-ffmpeg-9.0.2-bin/bin/ffmpeg
KIT=$HOME/nixos-config/result/bin/footage-clean
FP=$(sed -n "s|^FFPROBE=||p" $HOME/nixos-config/result/bin/footage-clean | tr -d "\"")
SUDO=/run/wrappers/bin/sudo
T="/ds-public/Family/Camcorder/8mm/Tape12"
EDL=$1; W=$2; OUT=$3
mkdir -p "$W"
declare -A PART
while IFS='|' read -r n f; do [ -n "${PART[$n]:-}" ] || PART[$n]="$f"; done \
  < <(grep '|' "$HOME/b12aud/index.txt" | sort)
ARGS=(--deint auto --denoise none --codec nvenc-hevc --crf 16 --preset slow
      --single-pass --source-color --me-search 5 --me-searchparam 3
      --me-range 32 --me-divide --me-rblk 16 --deint-degrain 0)
echo "$(date +%F_%T) T12-START stopping fah"
$SUDO -n systemctl stop fah-client
i=0; ok=1; sum=0
# NOTE: read on a dedicated FD (9). The kit's internal ffmpeg calls have no
# -nostdin: on the original loop they were launched from inside
# `while read ... done 9< "$EDL"` and STOLE the loop's stdin mid-line, so the
# next read() got a truncated EDL row (seg4 "nosrc 991.31"). Belt: </dev/null
# on the kit too; resume: already-rendered segments are kept.
while IFS=$'\t' read -r -u 9 cls src from len _o0 _o1 _bl; do
  i=$((i+1))
  if [ -s "$W/wseg$i.mkv" ]; then
    d0=$($FP -v error -show_entries format=duration -of default=nw=1:nk=1 "$W/wseg$i.mkv" 2>/dev/null)
    if [ -n "$d0" ]; then sum=$(awk -v a="$sum" -v b="$d0" 'BEGIN{printf "%.3f", a+b}'); echo "$(date +%F_%T) seg $i resume-skip dur=$d0 sum=$sum"; continue; fi
    rm -f "$W/wseg$i.mkv"
  fi
  if [ "$cls" = NEW ]; then IN="${PART[$src]:-}"; else IN="$T/$src"; fi
  [ -n "$IN" ] && [ -e "$IN" ] || { echo "SEGFAIL $i nosrc $cls $src"; ok=0; break; }
  to=$(awk -v a="$from" -v l="$len" 'BEGIN{printf "%.3f", a+l}')
  pd=$($FP -v error -show_entries format=duration -of default=nw=1:nk=1 "$IN" 2>/dev/null)
  awk -v f="$from" -v t="$to" -v d="$pd" 'BEGIN{exit !(f>=0 && t<=d+0.5)}' || \
    { echo "SEGFAIL $i range $from-$to vs dur=$pd ($IN)"; ok=0; break; }
  echo "$(date +%F_%T) seg $i $cls $src from=$from to=$to"
  if [ "$cls" = OLD ]; then
    # mp2-in-MPEG2-PS stream-copy into mkv fails (unknown timestamps);
    # normalize through MPEG-TS first, then hand the kit a whole file.
    if ! $FF -nostdin -v error -y -ss "$from" -i "$IN" -t "$len" -c copy -f mpegts "$W/pre$i.ts" 2>>"$W/rlog$i.txt"; then
      echo "SEGFAIL $i presplit"; tail -3 "$W/rlog$i.txt"; ok=0; break
    fi
    # mp2-in-PS stream-copy into MKV fails (mkv demands timestamps the PS
    # head lacks), and copy-based PS/MPEG-TS presplit inherits a 15 s audio
    # DTS overrun (-> 55 s "duration"). Re-encode the presplit instead:
    # mpeg2 q:v 2 (~50 Mbit/s) is far above these 6-9 Mbit/s sources, so the
    # extra generation is invisible before the crf-16 HEVC that follows.
    if ! $FF -nostdin -v error -y -ss "$from" -i "$IN" -t "$len" \
         -c:v mpeg2video -q:v 2 -c:a mp2 -b:a 256k "$W/presplit$i.mpg" 2>>"$W/rlog$i.txt"; then
      echo "SEGFAIL $i presplit"; tail -3 "$W/rlog$i.txt"; ok=0; break
    fi
    SRCARG=("$W/presplit$i.mpg"); EXTRA=()
  else
    SRCARG=("$IN"); EXTRA=(--from "$from" --to "$to")
  fi
  if ! "$KIT" "${ARGS[@]}" ${EXTRA[@]+"${EXTRA[@]}"} "${SRCARG[@]}" "$W/raw$i.mkv" < /dev/null > "$W/rlog$i.txt" 2>&1; then
    echo "SEGFAIL $i render"; tail -3 "$W/rlog$i.txt"; ok=0; break
  fi
  rm -f "$W/presplit$i.ts"
  $FF -nostdin -v error -y -i "$W/raw$i.mkv" -map 0:v:0 -map 0:a:0 \
      -c:v copy -c:a pcm_s16le "$W/wseg$i.mkv" 2>>"$W/rlog$i.txt" || \
    { echo "SEGFAIL $i audio"; tail -3 "$W/rlog$i.txt"; ok=0; break; }
  rm -f "$W/raw$i.mkv"
  d=$($FP -v error -show_entries format=duration -of default=nw=1:nk=1 "$W/wseg$i.mkv")
  tol=0.30; [ "$cls" = OLD ] && tol=3.0
  good=$(awk -v a="$d" -v b="$len" -v t="$tol" 'BEGIN{d2=a-b; if(d2<0)d2=-d2; print (d2<t)?1:0}')
  [ "$good" = 1 ] || { echo "SEGFAIL $i dur=$d want=$len"; ok=0; break; }
  sum=$(awk -v a="$sum" -v b="$d" 'BEGIN{printf "%.3f", a+b}')
  echo "  seg$i ok dur=$d sum=$sum"
done 9< "$EDL"
if [ $ok = 1 ]; then
  { for k in $(seq 1 $i); do printf "file '%s'\n" "$W/wseg$k.mkv"; done; } > "$W/wlist.txt"
  $FF -nostdin -v error -y -f concat -safe 0 -i "$W/wlist.txt" -c copy -avoid_negative_ts make_zero "$OUT" || ok=0
fi
$SUDO -n systemctl start fah-client && echo "$(date +%F_%T) fah restarted"
if [ $ok = 1 ]; then
  tot=$($FP -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT")
  g=$(awk -v s="$sum" -v t="$tot" -v n="$i" 'BEGIN{d=t-s; if(d<0)d=-d; print (d < 0.1+0.1*n) ? 1 : 0}')
  if [ "$g" = 1 ]; then echo "$(date +%F_%T) DONE $(du -h "$OUT" | cut -f1) dur=$tot sum=$sum segs=$i"
  else echo "$(date +%F_%T) FAIL dur-mismatch tot=$tot sum=$sum"; fi
else
  echo "$(date +%F_%T) FAIL"
fi
