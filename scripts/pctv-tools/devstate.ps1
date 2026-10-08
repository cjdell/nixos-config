# devstate.ps1 — PnP / driver state for the PCTV device tree, run inside the Win7 guest.
# PowerShell 2.0 compatible (the guest has .NET 3.5 / PS 2.0 only).
#   powershell -ExecutionPolicy Bypass -File C:\Users\Chris\devstate.ps1
param([string]$match = '2304')

"=== Win32_PnPEntity (DeviceID match '$match') ==="
Get-WmiObject Win32_PnPEntity | Where-Object { $_.DeviceID -match $match } | Sort-Object DeviceID | ForEach-Object {
  "NAME: " + $_.Name
  "  DeviceID:               " + $_.DeviceID
  "  Class:                  " + $_.Class
  "  PnPClass:               " + $_.PnPClass
  "  Status:                 " + $_.Status
  "  ConfigManagerErrorCode: " + $_.ConfigManagerErrorCode
  "  Service:                " + $_.Service
  "  CompatibleID:           " + ($_.CompatibleID -join ',')
  "  HardwareID:             " + ($_.HardwareID -join ',')
  ""
}

"=== Win32_PnPSignedDriver (DeviceID match '$match') ==="
Get-WmiObject Win32_PnPSignedDriver | Where-Object { $_.DeviceID -match $match } | ForEach-Object {
  "DeviceName:    " + $_.DeviceName
  "  InfName:       " + $_.InfName
  "  DriverVersion: " + $_.DriverVersion
  "  DriverDate:    " + $_.DriverDate
  "  ServiceName:   " + $_.ServiceName
  "  Signer:        " + $_.DriverSigner
  ""
}

"=== kernel driver services (Pinnacle / DiBcom) ==="
Get-WmiObject Win32_SystemDriver | Where-Object { $_.Name -match 'ltn|mod7700|dvb7700|pctv' } | ForEach-Object {
  ("{0,-22} state={1,-8} start={2,-10} path={3}" -f $_.Name, $_.State, $_.StartMode, $_.PathName)
}
