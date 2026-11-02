#!/usr/bin/env bash
# capture-selftest.sh - prove the capture path keeps every field, without a
# capture card, a tape or a deck.
#
#   ./capture-selftest.sh [-v]
#
# `fakeprobe.c` is a stand-in for `pctv_probe stream`: it emits real-time
# BT.656 in the exact line layout this card produces (SAV(4) + 1440 active +
# 284 tail = 1728 B, 288 active lines + 24 blanking per field, 50 fields/s), and
# can inject the two things that actually go wrong:
#
#   FAKE_GAP=<s>        remove 32768 bytes from the byte stream at t=<s>, mid
#                       line - one lost 32 KiB URB, the case that used to cost
#                       two whole fields and is now repaired at the seam
#   FAKE_GAPLINES=<s>   remove exactly 19 whole lines instead: guard codes stay
#                       1728 B apart, so *no* parser can see where they went -
#                       it has to show up as a short field and be held
#   FAKE_STALL=<s>      stop writing for FAKE_STALL_LEN s (data delayed, nothing
#                       lost)
#
# and the driver stalls the monitor itself with SIGSTOP, which is what "SSHing
# in makes it stutter" is: the main loop is away, the data piles up in the pipe
# and the probe's ring, and afterwards a dozen frames arrive at once.
#
# Every expectation is a number the monitor prints (dup / skip / short /
# repaired / held), i.e. exactly what you would check on a real capture - see
# docs/pctv-analog-capture.md section 14.5.
set -u
cd "$(dirname "$0")"
VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

TMP=$(mktemp -d "${TMPDIR:-/tmp}/pctv-selftest.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
OUT="$TMP/out"; mkdir -p "$OUT"

say() { printf '%s\n' "$*"; }
fail=0
pass() { printf '  PASS  %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

say "building pctv-monitor + fakeprobe (this is the slow part) ..."
DEV=$(nix build --no-link --print-out-paths nixpkgs#SDL2.dev)
OUTP=$(nix build --no-link --print-out-paths nixpkgs#SDL2)
ADEV=$(nix build --no-link --print-out-paths nixpkgs#alsa-lib.dev)
ALIB=$(nix build --no-link --print-out-paths nixpkgs#alsa-lib)
nix shell nixpkgs#gcc --command cc -O2 -o "$TMP/pctv-monitor" pctv-monitor.c \
    -I"$DEV/include/SDL2" -I"$ADEV/include" \
    -L"$OUTP/lib" -L"$ALIB/lib" -Wl,-rpath,"$OUTP/lib" -Wl,-rpath,"$ALIB/lib" \
    -lSDL2 -lasound -lm -lpthread || { say "build failed"; exit 1; }
nix shell nixpkgs#gcc --command cc -O2 -o "$TMP/fakeprobe" fakeprobe.c \
    || { say "fakeprobe build failed"; exit 1; }

# one capture; echoes the monitor's own summary of what happened
capture() {          # $1 = seconds, $2 = extra env ("A=B C=D"), $3 = label
    local secs=$1 envs=$2 label=$3 log="$TMP/$3.log"
    rm -f "$OUT"/pctv-cap-*
    env SDL_VIDEODRIVER=dummy PCTV_LOG=0 PCTV_PROBE="$TMP/fakeprobe" \
        PCTV_NO_SUDO=1 $envs "$TMP/pctv-monitor" -i composite --capture \
        --capture-seconds "$secs" --no-audio --master uyvy --out-dir "$OUT" \
        >"$TMP/$label.out" 2>"$log"
    grep -E "capture stopped|fields \(" "$log" | sed 's/^pctv-monitor: //'
    [ $VERBOSE = 1 ] && grep -E "anomalies" "$log" | sed 's/^/    /'
    return 0
}

# pull "KEY N" out of the two summary lines
num() {             # $1 = file, $2 = regex with one capture group
    sed -n "$2" "$1" | head -1
}

run_case() {        # $1 label, $2 secs, $3 env, $4.. asserts as "name min max"
    local label=$1 secs=$2 envs=$3
    shift 3
    say ""
    say "== $label"
    capture "$secs" "$envs" "$label" || true
    local log="$TMP/$label.log"
    local stopped fields
    stopped=$(grep "capture stopped" "$log" | head -1)
    fields=$(grep "fields (" "$log" | head -1)
    for a in "$@"; do
        local name rest lo hi
        name=${a%%:*}
    rest=${a#*:}
    lo=${rest%%:*}
    hi=${rest##*:}
        local got=""
        case "$name" in
            dup)      got=$(printf '%s' "$stopped" | sed -n 's/.*frames \[dup \([0-9][0-9]*\).*/\1/p') ;;
            skip)     got=$(printf '%s' "$stopped" | sed -n 's/.*skip \([0-9][0-9]*\).*/\1/p') ;;
            written)  got=$(printf '%s' "$stopped" | sed -n 's/.*B, \([0-9][0-9]*\) frames.*/\1/p') ;;
            short)    got=$(printf '%s' "$fields" | sed -n 's/.*(\([0-9][0-9]*\) short.*/\1/p') ;;
            repaired) got=$(printf '%s' "$fields" | sed -n 's/.*\([0-9][0-9]*\) repaired at the seam.*/\1/p') ;;
            held)     got=$(printf '%s' "$fields" | sed -n 's/.*\([0-9][0-9]*\) held (gate).*/\1/p') ;;
            *) say "  (unknown assertion $name)"; continue ;;
        esac
        if [ -z "$got" ]; then bad "$name: not in the summary"; continue; fi
        if [ "$got" -ge "$lo" ] && [ "$got" -le "$hi" ]; then
            pass "$name = $got (want $lo..$hi)"
        else
            bad "$name = $got (want $lo..$hi)"
        fi
    done
}

# 12 s of clean stream: 25 fps * 12 = 300 pictures, no repeats, no evictions.
run_case "clean" 12 "" \
    written:290:335 dup:0:0 skip:0:0 short:0:0 held:0:0

# One lost 32 KiB URB mid-field.  The seam is locatable, the field is repaired
# from the last clean frame, and the cadence is untouched: no repeat, no hold.
run_case "one lost URB (32768 B, mid-line)" 12 "FAKE_GAP=4" \
    dup:0:0 skip:0:0 short:0:0 repaired:1:3 held:0:0

# A hole aligned to whole lines cannot be located by any parser; the field has
# to be held (one repeated picture), which is the honest worst case.
run_case "19 aligned lines dropped" 12 "FAKE_GAPLINES=4" \
    dup:0:0 skip:0:0 short:1:2 held:1:2

# The host is away for a second (SIGSTOP): data waits in the pipe, nothing is
# lost, and - crucially - the writer must NOT repeat pictures to "fill" it.
say ""
say "== 1 s driver freeze (SIGSTOP, nothing lost)"
rm -f "$OUT"/pctv-cap-*
SDL_VIDEODRIVER=dummy PCTV_LOG=0 PCTV_PROBE="$TMP/fakeprobe" PCTV_NO_SUDO=1 \
    "$TMP/pctv-monitor" -i composite --capture --capture-seconds 12 --no-audio \
    --master uyvy --out-dir "$OUT" >"$TMP/freeze.out" 2>"$TMP/freeze.log" &
mpid=$!
sleep 5
kill -STOP "$mpid" 2>/dev/null
sleep 1
kill -CONT "$mpid" 2>/dev/null
wait "$mpid"
grep -E "capture stopped|fields \(" "$TMP/freeze.log" | sed 's/^pctv-monitor: //'
stopped=$(grep "capture stopped" "$TMP/freeze.log" | head -1)
fields=$(grep "fields (" "$TMP/freeze.log" | head -1)
for a in dup:0:0 skip:0:0 short:0:0 held:0:0 written:290:335; do
    name=${a%%:*}
    rest=${a#*:}
    lo=${rest%%:*}
    hi=${rest##*:}
    case "$name" in
        dup)     got=$(printf '%s' "$stopped" | sed -n 's/.*frames \[dup \([0-9][0-9]*\).*/\1/p') ;;
        skip)    got=$(printf '%s' "$stopped" | sed -n 's/.*skip \([0-9][0-9]*\).*/\1/p') ;;
        written) got=$(printf '%s' "$stopped" | sed -n 's/.*B, \([0-9][0-9]*\) frames.*/\1/p') ;;
        short)   got=$(printf '%s' "$fields" | sed -n 's/.*(\([0-9][0-9]*\) short.*/\1/p') ;;
        held)    got=$(printf '%s' "$fields" | sed -n 's/.*\([0-9][0-9]*\) held (gate).*/\1/p') ;;
    esac
    if [ -n "$got" ] && [ "$got" -ge "$lo" ] && [ "$got" -le "$hi" ]; then
        pass "$name = $got (want $lo..$hi)"
    else
        bad "$name = ${got:-?} (want $lo..$hi)"
    fi
done

say ""
if [ "$fail" -eq 0 ]; then
    say "all checks passed"
else
    say "$fail check(s) FAILED"
fi
exit $((fail > 0))
