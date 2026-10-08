#!/usr/bin/env bash
# Bring up the DIB7700P analog-ADC output path and try to capture from the
# DiB0700 bulk IN endpoints.  Requires: device healthy, kernel driver unbound.
#
#   ./analog-attempt.sh [ep] [bytes] [outfile]
cd "$(dirname "$0")"
EP=${1:-0x82}; N=${2:-8192}; OUT=${3:-/tmp/pctv/analog.raw}
P="sudo ./pctv_probe"

dwr() { $P raw4 out 0x03 0x80 "$(printf 0x%02x $(( ($1>>8)&0xff )))" "$(printf 0x%02x $(( $1&0xff )))" "$(printf 0x%02x $(( ($2>>8)&0xff )))" "$(printf 0x%02x $(( $2&0xff )))" >/dev/null; }
drd() { $P rd2 0x40 "$(printf 0x%02x $(( ($1>>8)&0xff )))" "$(printf 0x%02x $(( $1&0xff )))" 2 2>/dev/null | tail -1; }

echo "-- demod id (want 01 b3 / 40 00)"
echo "   reg768: $(drd 768)   reg769: $(drd 769)"

echo "-- DIB7000P_POWER_ALL (regs 774,775,776,899 = 0; 1280 &= 0x1ff)"
r1280hex=$(drd 1280 | grep -oE '[0-9a-f]{2} [0-9a-f]{2}' | tr -d ' ')
if [ -n "$r1280hex" ]; then r1280=$((16#$r1280hex)); else r1280=0; fi
echo "   reg1280 read: $r1280"
dwr 774 0x0000; dwr 775 0x0000; dwr 776 0x0000; dwr 899 0x0000
dwr 1280 $(( r1280 & 0x1ff ))
echo "   774=$(drd 774) 775=$(drd 775) 776=$(drd 776) 899=$(drd 899) 1280=$(drd 1280)"

echo "-- sram lead-in: reg1287 = 0x0003"
dwr 1287 0x0003; echo "   reg1287: $(drd 1287)"

echo "-- OUTMODE_ANALOG_ADC: reg1286 = 0x04c0"
dwr 1286 0x04c0; echo "   reg1286: $(drd 1286)"

echo "-- smooth/ADC blocks (reg 235 smo_mode, 236 fifo threshold, 1925 slow adc)"
echo "   235=$(drd 235) 236=$(drd 236) 1925=$(drd 1925)"

echo "-- DiB0700 REQUEST_ENABLE_VIDEO: streaming on, ANALOG, 625"
$P video on analog 625 2>&1 | tail -1

echo "-- capture EP $EP"
$P cap "$EP" "$N" "$OUT" 2>&1 | tail -3
echo "-- capture EP3 (fallback)"
$P cap 0x83 4096 /tmp/pctv/analog_ep3.raw 2>&1 | tail -2
echo "-- capture EP1 (interrupt)"
$P cap 0x81 512 /tmp/pctv/analog_ep1.raw 2>&1 | tail -2
