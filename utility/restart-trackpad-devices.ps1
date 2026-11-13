<#
.SYNOPSIS
  Restarts all PnP devices whose instance name matches the Magic Trackpad
  vendor IDs (05AC = wired USB, 0001004C = Bluetooth), forcing the driver to
  re-read its settings with the current defaults.
#>
$ErrorActionPreference = 'Stop'
$pattern = '05AC|0001004C'
$devices = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.DeviceID -match $pattern })
if (-not $devices) {
    Write-Host 'NO_DEVICES_MATCHED'
    exit 0
}
foreach ($d in $devices) {
    Write-Host ("RESTART {0} (status={1})" -f $d.DeviceID, $d.Status)
    pnputil /restart-device $d.DeviceID 2>&1 | ForEach-Object { Write-Host $_ }
}
Start-Sleep -Seconds 8
Write-Host '--- POST-RESTART STATE ---'
@(Get-CimInstance Win32_PnPEntity | Where-Object { $_.DeviceID -match $pattern }) |
    ForEach-Object { Write-Host ("{0} => {1}" -f $_.DeviceID, $_.Status) }
Write-Host 'RESTART_DONE'
