#!/run/current-system/sw/bin/bash
# Per-block alignment verification: 2x2 grids (old-head | new-head / old-tail | new-tail)
set -u
export PATH=/run/current-system/sw/bin:/nix/store/9qh7i54hk78czcdvxwd78q4i1idc9mc3-ffmpeg-9.0.2-bin/bin:/bin:/usr/bin
FF=/nix/store/9qh7i54hk78czcdvxwd78q4i1idc9mc3-ffmpeg-9.0.2-bin/bin/ffmpeg
IDX=$HOME/b12aud/index.txt
OLD=/ds-public/Family/Camcorder/8mm/Tape12
V=/home/cjdell/b12render/verify
mkdir -p $V
P(){ grep "^$1|" "$IDX" | cut -d'|' -f2; }
fr(){ # fr out png src t
  $FF -nostdin -v error -y -ss $3 -i "$2" -frames:v 1 -vf "scale=320:256" "$1" 2>/dev/null
}
blk(){ # blk id oldf ot oldf2 ot2 nk nt nk2 nt2
  local id=$1 of=$2 ot=$3 of2=$4 ot2=$5 nk=$6 nt=$7 nk2=$8 nt2=$9
  fr $V/${id}_oh.mkv.png "$OLD/NVECapture.$of.mpg" $ot
  fr $V/${id}_nh.mkv.png "$(P $nk)" $nt
  fr $V/${id}_ot.mkv.png "$OLD/NVECapture.$of2.mpg" $ot2
  fr $V/${id}_nt.mkv.png "$(P $nk2)" $nt2
  $FF -nostdin -v error -y -i $V/${id}_oh.mkv.png -i $V/${id}_nh.mkv.png -i $V/${id}_ot.mkv.png -i $V/${id}_nt.mkv.png -filter_complex "[0][1]hstack[t];[2][3]hstack[b];[t][b]vstack" -frames:v 1 $V/blk$id.png 2>/dev/null
  echo "$(date +%T) blk$id"
}
# id oldf oldt oldf2 oldt2 newk newt newk2 newt2
blk 05 0002 381.1 0002 473.1 11 921.0 11 1013.0
blk 08 0002 727.5 0003 168.3 15 521.0 04 279.0
blk 13 0003 195.2 0003 273.3 15 721.0 15 799.0
blk 15 0003 469.4 0003 634.7 15 1841.0 15 1159.0
blk 19 0003 676.9 0003 795.1 15 1201.0 15 1319.0
blk 24 0006 19.6 0007 6.6 15 1521.0 17 719.0
blk 28 0007 12.6 0009 11.0 04 1258.0 04 1271.0
blk 31 0010 2.3 0011 46.2 04 1276.0 15 1793.0
blk 37 0012 15.6 0014 127.1 04 1441.0 04 2079.0
blk 41 0014 237.0 0014 315.1 17 81.0 17 159.0
blk 44 0015 27.2 0015 176.4 17 201.0 15 2199.0
blk 48 0015 227.9 0015 346.1 09 401.0 09 519.0
blk 50 0015 360.7 0015 416.0 11 24.0 11 79.0
blk 52 0015 468.3 0015 1547.1 17 641.0 17 1720.0
blk 54 0015 1589.2 0015 2298.7 17 1761.0 11 1959.0
blk 57 0015 2340.9 0015 2459.0 11 2001.0 11 2119.0
echo VERIFY-DONE
