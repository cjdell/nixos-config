#!/run/current-system/sw/bin/bash
# Targeted wash probe: per-frame means -> wash runs, for part windows and old files.
set -u
export PATH=/run/current-system/sw/bin:/nix/store/9qh7i54hk78czcdvxwd78q4i1idc9mc3-ffmpeg-9.0.2-bin/bin:/bin:/usr/bin
FF=/nix/store/9qh7i54hk78czcdvxwd78q4i1idc9mc3-ffmpeg-9.0.2-bin/bin/ffmpeg
IDX=$HOME/b12aud/index.txt
OLD=/ds-public/Family/Camcorder/8mm/Tape12
runprobe(){
  LBL=$1; SRC=$2; A=$3; B=$4
  DUR=$(awk -v a=$A -v b=$B 'BEGIN{print b-a}')
  echo "== $LBL src $A-$B"
  $FF -nostdin -v error -y -ss $A -t $DUR -i "$SRC" -vf "signalstats,metadata=print:file=/tmp/pm.txt" -an -f null - 2>/dev/null
  awk -v OF=$A '
    /^frame:/{ t=substr($3,10)+0 }
    /lavfi.signalstats.YAVG=/{ split($0,b,"="); y=b[2] }
    /lavfi.signalstats.UAVG=/{ split($0,b,"="); u=b[2] }
    /lavfi.signalstats.VAVG=/{
      split($0,b,"="); v=b[2]; d=u-v; s+=1
      wash = ((u>165 && d>45 && y<150) || (y>228 && d<18 && d>-18))
      if (wash) { if (!run) st=k; run=1; n++ }
      else { if (run) printf "  wash %.2f-%.2f\n", OF+(st-1)/25, OF+(k-1)/25; run=0 }
      k+=1
    }
    END{
      if (run) printf "  wash %.2f-%.2f(eof)\n", OF+(st-1)/25, OF+s/25
      if (n==0) print "  clean"
    }
  ' /tmp/pm.txt
}
P(){ grep "^$1|" "$IDX" | cut -d'|' -f2; }
runprobe n_11  "$(P 11)" 1004 1015
runprobe n_17  "$(P 17)" 588 598
runprobe n_15  "$(P 15)" 1911 1921
runprobe n_04  "$(P 04)" 179 188
runprobe old0003 $OLD/NVECapture.0003.mpg 66 80
runprobe old0010 $OLD/NVECapture.0010.mpg 15 30
runprobe old0011 $OLD/NVECapture.0011.mpg 46 56
runprobe old0013 $OLD/NVECapture.0013.mpg 470 499
echo MEANS-PROBE-DONE
