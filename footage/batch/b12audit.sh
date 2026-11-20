#!/run/current-system/sw/bin/bash
# Dell 12 independent audit pass: full re-census of the rendered watch copy.
# Produces per-second bins (tot frames, strict-blue frames, hi-diff frames)
# + silence report. Read-only on the output. Terminal marker AUD12-DONE.
set -uo pipefail
export PATH=/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin
FF=/nix/store/9qh7i54hk78czcdvxwd78q4i1idc9mc3-ffmpeg-9.0.2-bin/bin/ffmpeg
O="$1"; W="$2"
mkdir -p "$W"
echo "$(date +%T) AUD12-START"
$FF -nostdin -v error -y -i "$O" \
  -vf "signalstats,metadata=print:file=$W/aud_stats.txt" -an -f null - 2>"$W/aud_v.err" || echo AUDVFAIL
awk '
  /^frame:/{ for(j=1;j<=NF;j++) if($j ~ /^pts_time:/){split($j,a,":"); s=int(a[2])} }
  /UAVG/{split($0,b,"=");u=b[2]} /VAVG/{split($0,b,"=");v=b[2]} /YAVG/{split($0,b,"=");y=b[2]}
  /YDIF/{split($0,e,"=");yd=e[2]} /UDIF/{split($0,e,"=");ud=e[2]}
  /VDIF/{split($0,e,"=");vd=e[2]; d=u-v
    tot[s]++; if(d>80 && y<120) bl[s]++
    m=yd; if(ud>m)m=ud; if(vd>m)m=vd; if(m>40) hi[s]++; if(m>90) vr[s]++ }
  END{ for(k=0;k<=int(s);k++) printf "%d %d %d %d %d\n", k, tot[k]+0, bl[k]+0, hi[k]+0, vr[k]+0 }
' "$W/aud_stats.txt" > "$W/aud_d.tsv"
rm -f "$W/aud_stats.txt"
$FF -nostdin -v error -i "$O" -map 0:a -af silencedetect=n=-50dB:d=2.5 -f null - 2>&1 \
  | grep -E "silence_(start|duration)" > "$W/aud_sil.txt" || true
wc -l "$W/aud_d.tsv"
echo "$(date +%T) AUD12-DONE"
