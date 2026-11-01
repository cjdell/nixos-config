#!/bin/sh
# pctv-field-order - ask a capture what field order it claims, three ways, and
# say what can still be done about it.  See the section at the bottom of
# docs/pctv-analog-capture.md ("Capture masters, field order, 50p") for where
# each reading comes from and why the PCTV's picture is top-field-first.
#
# An interlaced file can disagree with itself, so print all three:
#
#   container  the Matroska FieldOrder element (ffprobe's `field_order`).  Only
#              exists per container - MPEG-PS/.mpg has no such element, which is
#              why an MPEG-2 master's order lives solely in the bitstream.
#   frames     interlaced_frame,top_field_first on the decoded frames.  What
#              idet, yadif/bwdif, ffms2 and l-smash consult, so in practice the
#              reading that decides whether 50p comes out in time order.
#   pixels     idet's read of the frames.  Establishes that the capture really is
#              interlaced (non-repeating fields); its TFF/BFF lean is NOT a
#              reliable field-order instrument - two synthetic clips differing
#              only in which field is temporally first voted 9/10 and 10/9, see
#              docs/pctv-analog-capture.md §10.3.
#
# Usage:
#   pctv-field-order FILE...            report
#   pctv-field-order --relabel FILE...  also write FILE.tt.mkv: stream-copied
#       Matroska with the container element set (audio and video are copied, the
#       original is left alone).  For .mpg this fixes only the CONTAINER - the
#       frames keep saying 1,0, because top_field_first is an MPEG-2 bitstream
#       syntax element and no lossless operation rewrites it.  New captures
#       (PCTV_MASTER=uyvy|ffv1) get the frame flag right at capture time.
set -eu

FFMPEG=${FFMPEG:-@ffmpeg@}
FFPROBE=${FFPROBE:-@ffprobe@}
ORDER=${PCTV_FIELD_ORDER:-tt}

usage() {
    sed -n '/^# Usage:/,/^set -eu/p' "$0" | sed 's/^# \{0,1\}//;/^set -eu/d'
}

mode=report
case "${1:-}" in
    --relabel) mode=relabel; shift ;;
    --check) shift ;;
esac
case "${1:-}" in
    "" | -h | --help) usage; exit 2 ;;
esac

rc=0

# idet's summary over 4 s: the "Repeated Fields" line says whether the picture is
# interlaced at all (non-repeated fields), the "Single frame detection" line is its
# field-order lean.  ffmpeg prints a spurious all-zero summary first, so take the
# LAST pair.  Prints "<neither> <top> <bottom> <tff> <bff>".
idet_read() {
    raw=$($FFMPEG -v info -nostats ${2:+-ss "$2"} -t 4 -i "$1" -an -vf idet -f null - 2>&1 \
          | grep -E 'Repeated Fields:|Single frame detection:' | tail -2)
    printf '%s %s' \
        "$(printf '%s\n' "$raw" | sed -n 's/.*Neither: *\([0-9]*\) Top: *\([0-9]*\) Bottom: *\([0-9]*\).*/\1 \2 \3/p')" \
        "$(printf '%s\n' "$raw" | sed -n 's/.*Single frame detection: TFF: *\([0-9]*\) BFF: *\([0-9]*\).*/\1 \2/p')"
}

for f in "$@"; do
    if [ ! -r "$f" ]; then echo "pctv-field-order: $f: not readable" >&2; rc=1; continue; fi

    container=$($FFPROBE -v error -select_streams v -show_entries stream=field_order \
                -of csv=p=0 "$f" 2>/dev/null | cut -d, -f1 | head -1)
    frames=$($FFPROBE -v error -select_streams v -show_frames -read_intervals "%+2" \
             -show_entries frame=interlaced_frame,top_field_first -of csv=p=0 "$f" 2>/dev/null \
             | cut -d, -f1,2 | tr -d ' ' | sort -u | paste -sd ' ' -)
    idet=$(idet_read "$f")
    # The head of a recording is often a static shot, black frames or bars, where
    # every field repeats and idet learns nothing.  Move 30 s in before concluding.
    case "$idet" in "" | 0\ 0\ 0\ 0\ 0) idet=$(idet_read "$f" 30) ;; esac
    set -- $idet   # safe: the `for f in "$@"` word list was already expanded
    inter_total=$(( ${1:-0} + ${2:-0} + ${3:-0} ))
    if [ "${4:-0}" = 0 ] && [ "${5:-0}" = 0 ]; then
        idet="nothing measurable in the sample (static picture?)"
    else
        idet="interlaced: ${1:-0}/${inter_total} fields non-repeating; order lean TFF ${4:-0} / BFF ${5:-0} - NOT decisive (see docs §10.3), interlaced-ness yes"
    fi

    printf '%s\n  container=%s  frames=[%s]  idet: %s\n' \
           "$f" "${container:-none}" "${frames:-none}" "${idet:-not measurable}"

    case "$frames" in
        1,1*)
            echo "  Frames are stamped top-field-first: deinterlace as it stands." ;;
        1,0*)
            echo "  Frames claim BOTTOM-first.  The PCTV's picture is TOP-first"
            echo "  (BT.656 field 1 = the field with line 1 = the top field, and"
            echo "  625/50 displays the field it transmits first) - this tag comes"
            echo "  from the mpeg2 encoder's default, not from the signal."
            echo "  MPEG-2 cannot be relabelled at frame level (--relabel rewrites"
            echo "  the container only), so declare it in the post script:"
            echo "  AssumeTFF() in AviSynth+, SetFieldBased(1) in VapourSynth." ;;
        "" | 0,0*)
            echo "  No field flag on the frames: declare the order in the post script." ;;
    esac

    if [ "$mode" = relabel ]; then
        out="${f%.*}.$ORDER.mkv"
        if [ "$out" = "$f" ]; then echo "  --relabel: refusing to overwrite the input" >&2; rc=1; continue; fi
        echo "  relabelling -> $out (stream copy: no re-encode, original untouched)"
        # +genpts: an MPEG-PS audio packet with no valid start timestamp otherwise
        # kills the Matroska muxer ("Can't write packet with unknown timestamp").
        $FFMPEG -v error -y -fflags +genpts -field_order "$ORDER" -i "$f" \
                -c copy -field_order "$ORDER" -f matroska "$out"
        new=$($FFPROBE -v error -select_streams v -show_entries stream=field_order \
              -of csv=p=0 "$out" 2>/dev/null | cut -d, -f1 | head -1)
        nf=$($FFPROBE -v error -select_streams v -show_frames -read_intervals "%+1" \
             -show_entries frame=interlaced_frame,top_field_first -of csv=p=0 "$out" 2>/dev/null \
             | cut -d, -f1,2 | tr -d ' ' | sort -u | paste -sd ' ' -)
        echo "  wrote container=${new:-none} frames=[$nf]"
    fi
done
exit $rc
