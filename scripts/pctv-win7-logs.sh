#!/usr/bin/env bash
#
# pctv-win7-logs.sh — dump a standard bundle of PCTV/driver state from the win7
# guest into a host-side log file. Run it BEFORE and AFTER a driver change so the
# two dumps can be diffed.
#
#   ./scripts/pctv-win7-logs.sh <label>
#
# Writes pctv-linux/logs/guest-<label>.txt (plus a marker line with the epoch, so
# a host-side usbmon capture can be sliced against it — see pctv-linux/mark.sh).
#
# Everything is read-only except the log file. Safe to run repeatedly.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

LABEL="${1:?usage: pctv-win7-logs.sh <label>}"
S=./scripts/pctv-win7-ssh.sh
LOG="pctv-linux/logs/guest-$LABEL.txt"
mkdir -p pctv-linux/logs

# one guest command per line; run through cmd.exe, errors are fine
run() {
  local title="$1"; shift
  {
    echo ""
    echo "################ $title"
    timeout 90 $S "$*" 2>/dev/null
  } >>"$LOG"
}

echo "$(date +%s)  $(date '+%H:%M:%S')  guest-logs:$LABEL" | tee -a "pctv-linux/logs/timeline-$LABEL.txt"

{
  echo "=== pctv-win7-logs label=$LABEL host=$(date -Is) epoch=$(date +%s) ==="
} >"$LOG"

run "uptime/whoami"            'whoami & echo now=%date% %time%'
run "computer system"          'wmic computersystem get Name,Manufacturer,Model,PCSystemType /value'
run "os"                       'wmic os get Caption,Version,BuildNumber,InstallDate /value'
run "boot config (signing)"    'bcdedit /enum {current}'
run "driver store (pnp)"       'pnputil -e'
run "pnp device tree (ps1)"    'powershell -ExecutionPolicy Bypass -File C:\Users\Chris\devstate.ps1'
run "driver services"          'sc query Ltn_hyd7700pc_64 & sc query mod7700 & sc query dvb7700all'
run "service image paths"      'sc qc Ltn_hyd7700pc_64 & sc qc mod7700'
run "device params registry"   'reg query "HKLM\SYSTEM\CurrentControlSet\Enum\USB\VID_2304&PID_022E" /s'
run "mod7700 service key"      'reg query "HKLM\SYSTEM\CurrentControlSet\Services\mod7700" /s'
run "hyd service key"          'reg query "HKLM\SYSTEM\CurrentControlSet\Services\Ltn_hyd7700pc_64" /s'
run "DirectShow capture devs"  'C:\Users\Chris\dsenum.exe'
run "PCTV filter pin tree"     'C:\Users\Chris\dstree.exe'
run "crossbar page read"       'C:\Users\Chris\pctvroute.exe read'
run "kernel drivers (pctv)"    'driverquery /v /fo csv | findstr /i "mod7700 hyd7700 dvb7700 pctv pinnacle"'
run "system errors (last 25)"  'wevtutil qe System /q:"*[System[(Level<=2)]]" /c:25 /rd:true /f:text'
run "device setup mgr (last 15)" 'wevtutil qe "Microsoft-Windows-DeviceSetupManager/Admin" /c:15 /rd:true /f:text'
run "codeintegrity (last 15)"  'wevtutil qe "Microsoft-Windows-CodeIntegrity/Operational" /c:15 /rd:true /f:text'
run "crash dumps"              'dir C:\Windows\MEMORY.DMP C:\Windows\Minidump 2>nul'

# setupapi.dev.log is the SetupAPI driver-install log - pull the whole file and
# keep the tail (it is the primary record of what the install did/failed on)
{
  echo ""
  echo "################ setupapi.dev.log (tail 400)"
  timeout 90 $S --get 'C:/Windows/INF/setupapi.dev.log' "/tmp/setupapi-$LABEL.log" 2>/dev/null
  tail -400 "/tmp/setupapi-$LABEL.log" 2>/dev/null || echo "(could not fetch setupapi.dev.log)"
} >>"$LOG"

echo "-> $LOG ($(wc -l <"$LOG") lines)"
