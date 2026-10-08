# pnpreset.ps1 — disable + re-enable a PnP device node (forces PnP to re-start the
# driver without a reboot or a physical unplug).
#   powershell -ExecutionPolicy Bypass -File C:\Users\Chris\pnpreset.ps1 ["USB\VID_2304&PID_022E\0000000100"]
param([string]$id = 'USB\VID_2304&PID_022E\0000000100')

# WQL string literals need backslashes doubled
$esc = $id.Replace('\', '\\').Replace("'", "\'")
$f = "DeviceID='" + $esc + "'"
$d = Get-WmiObject Win32_PnPEntity -Filter $f
if ($d -eq $null) { "no such device: $id"; exit 1 }
"before : " + $d.Name + "  err=" + $d.ConfigManagerErrorCode
$r = $d.Disable(); "disable -> " + $r.ReturnValue
Start-Sleep -Seconds 3
$d = Get-WmiObject Win32_PnPEntity -Filter $f
$r = $d.Enable(); "enable  -> " + $r.ReturnValue
Start-Sleep -Seconds 6
$d = Get-WmiObject Win32_PnPEntity -Filter $f
"after  : " + $d.Name + "  err=" + $d.ConfigManagerErrorCode + "  status=" + $d.Status
