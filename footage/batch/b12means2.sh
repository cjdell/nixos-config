#!/run/current-system/sw/bin/bash
# Per-frame luma/chroma means for TEMPORAL wash detection — run over the
# rendered wseg files (local disk, 5.8 GB) instead of the 140 GB NFS masters.
# Output: ~/b12aud/s_<seg>.tsv cols: t yavg uavg vavg   (t = within-segment)
set -u
export PATH=/run/current-system/sw/bin:/nix/store/9qh7i54hk78czcdvxwd78q4i1idc9mc3-ffmpeg-9.0.2-bin/bin:/bin:/usr/bin
FF=/nix/store/9qh7i54hk78czcdvxwd78q4i1idc9mc3-ffmpeg-9.0.2-bin/bin/ffmpeg
OUT=$HOME/b12aud/segmeans
mkdir -p $OUT
for F in $HOME/b12render/seg/wseg*.mkv; do
  B=$(basename "$F" .mkv)
  [ -s "$OUT/$B.tsv" ] && continue
  $FF -nostdin -v error -y -i "$F" -vf "signalstats,metadata=print:file=$OUT/tmp_$B.txt" -an -f null - 2>/dev/null
  awk '
    /^frame:/{ t=substr($3,10)+0 }
    /lavfi.signalstats.YAVG=/{split($0,b,"="); y=b[2]}
    /lavfi.signalstats.UAVG=/{split($0,b,"="); u=b[2]}
    /lavfi.signalstats.VAVG=/{split($0,b,"="); v=b[2]; printf "%.3f %.1f %.1f %.1f\n", t, y, u, v}
  ' "$OUT/tmp_$B.txt" > "$OUT/$B.tsv"
  rm -f "$OUT/tmp_$B.txt"
  echo "$(date +%T) $B"
done
echo "WSEGMEANS-DONE"
