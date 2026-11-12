#!/usr/bin/env bash
# capture-selftest.sh - prove the capture path keeps every field, without a
# capture card, a tape or a deck.
#
#   ./capture-selftest.sh [-v]
#
# `fakeprobe.c` is a stand-in for `pctv_probe stream`: it emits real-time
# BT.656 in the exact line layout this card produces (SAV(4) + 1440 active +
# 284 tail = 1728 B, 288 active lines + 24 blanking per field, 50 fields/s), and
# can inject the things that actually go wrong:
#
#   FAKE_GAP=<s>        remove 32768 bytes from the byte stream at t=<s>, mid
#                       line - one lost 32 KiB URB, the case that used to cost
#                       two whole fields and is now repaired at the seam
#   FAKE_GAPLINES=<s>   remove exactly 19 whole lines instead: guard codes stay
#                       1728 B apart, so *no* parser can see where they went -
#                       it has to show up as a short field and be held
#   FAKE_MULTIGAP=<s>   eight dropouts through one field's vertical interval,
#                       each proving one advanced row: a damaged tape's
#                       rotation.  This is the shape that segfaulted the live
#                       monitor five times on macbook-pro-2009 (2026-11-05..12)
#                       when the row repair indexed past the good-frame buffer
#                       - the case run twice, once plain and once under
#                       AddressSanitizer, which catches that overrun with or
#                       without heap slack to hide it in.
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
# AddressSanitizer build, for the one case whose bug a full page of heap slack
# can hide (it did, five crashes deep: the overflow reads only 1.8 KB past the
# buffer, so whether it SIGSEGVs is allocator luck - ASan makes it a fact).
nix shell nixpkgs#gcc --command cc -O1 -g -fsanitize=address -o "$TMP/pctv-monitor-asan" pctv-monitor.c \
    -I"$DEV/include/SDL2" -I"$ADEV/include" \
    -L"$OUTP/lib" -L"$ALIB/lib" -Wl,-rpath,"$OUTP/lib" -Wl,-rpath,"$ALIB/lib" \
    -lSDL2 -lasound -lm -lpthread || { say "ASan build failed"; exit 1; }
# nixpkgs' SDL2 is now the sdl2-compat shim, which dlopens libSDL3 at runtime;
# under the ASan runtime that dlopen misses the store paths, so name them.
S3=$(nix-store -q --references "$OUTP" 2>/dev/null | grep -iE "sdl3" | head -1)

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

# A damaged rotation: eight dropouts inside one field, each of which the pitch
# can only prove ONE row of, so their sum walks the row-repair counter through
# the vertical interval - and into the rows where it used to index past the
# good-FRAME buffer (field_fill_rows read good_fuv[2r+parity] with r up to 295
# against a 576-row allocation).  Five SIGSEGVs on macbook-pro-2009, always
# over a bad stretch of tape, always mid-capture (2026-11-05..12).  The tape
# itself must lose nothing beyond the dropouts themselves.
run_case "damaged rotation (8 VBI dropouts, one field)" 12 "FAKE_MULTIGAP=4" \
    dup:0:0 skip:0:0 written:290:335 short:0:0 held:0:0

# The same case under AddressSanitizer: the overrun is 1.8 KB, which a heap
# page of slack can survive - on zen3 it did, on the macbook it SIGSEGVed 5/5.
# ASan makes the absence of the overflow a fact, not allocator luck.
say ""
say "== damaged rotation under AddressSanitizer (the 2026-11-12 overrun, named)"
rm -f "$OUT"/pctv-cap-*
env SDL_VIDEODRIVER=dummy PCTV_LOG=0 ASAN_OPTIONS=detect_leaks=0 \
    LD_LIBRARY_PATH="$OUTP/lib${S3:+:$S3/lib}" \
    PCTV_PROBE="$TMP/fakeprobe" PCTV_NO_SUDO=1 FAKE_MULTIGAP=4 \
    "$TMP/pctv-monitor-asan" -i composite --capture --capture-seconds 12 --no-audio \
    --master uyvy --out-dir "$OUT" >"$TMP/asan.out" 2>"$TMP/asan.log"
if grep -q "ERROR: AddressSanitizer" "$TMP/asan.log"; then
    bad "AddressSanitizer caught the row-repair overrun:"
    grep -a -m3 -E "ERROR: AddressSanitizer|field_fill_rows|gap_resync" "$TMP/asan.log" | sed 's/^/    /'
elif ! grep -q "capture stopped" "$TMP/asan.log"; then
    bad "the ASan run never finished (see $TMP/asan.log)"
else
    pass "no heap overrun across 12 s of damaged rotation (ASan)"
fi

# End of tape: the deck shows its blue screen.  The file must close with
# everything in it complete - and the RUN must not: it used to quit ("ends
# the run and releases the card"), which on an unattended batch meant the
# next tape met a dead window.  So: a tape plays, ends, and is replaced, and
# the test is two files from one process with no human in between.
say ""
say "== blue closes the file, the monitor waits for the next tape"
rm -f "$OUT"/pctv-cap-*
env SDL_VIDEODRIVER=dummy PCTV_LOG=0 PCTV_PROBE="$TMP/fakeprobe" PCTV_NO_SUDO=1 \
    FAKE_BLUE=4:5 PCTV_BLUE_SECS=3 \
    timeout 60 "$TMP/pctv-monitor" -i composite --capture --capture-seconds 14 \
    --no-audio --master uyvy --out-dir "$OUT" >"$TMP/blue.out" 2>"$TMP/blue.log"
rc=$?
grep -E "tape is finished|picture again ->" "$TMP/blue.log" \
    | sed 's/^pctv-monitor: //' | cut -c1-150
nblue=$(ls "$OUT"/pctv-cap-*.mkv 2>/dev/null | wc -l)
[ $rc -eq 0 ] && pass "survived the blue timeout (exit 0, ran on)" \
    || bad "monitor exit $rc - blue must close the file, not end the run"
grep -q "blue screen for 3 s, so this tape is finished" "$TMP/blue.log" \
    && pass "blue closed the file after the timeout" \
    || bad "no blue close (PCTV_BLUE_SECS=3, FAKE_BLUE=4:5)"
grep -q "picture again ->" "$TMP/blue.log" \
    && pass "a replaced tape reopens recording by itself" \
    || bad "no reopen when the picture came back"
[ "$nblue" -eq 2 ] && pass "two tapes, two files, one process" \
    || bad "$nblue files, want 2"

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
