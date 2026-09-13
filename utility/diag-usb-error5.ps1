# diag-usb-error5.ps1 - experiment: disable/enable MI_00 alone, observe if the error clears
$ErrorActionPreference = 'Continue'
$mi00 = 'USB\VID_05AC&PID_0324&MI_00\7&17F26F02&0&0000'

function Get-Status($id) {
    $d = Get-CimInstance Win32_PnPEntity | Where-Object { $_.DeviceID -eq $id }
    if (-not $d) { return 'NOT_FOUND' }
    return ("Status={0} CfgErr={1} Service={2}" -f $d.Status, $d.ConfigManagerErrorCode, $d.Service)
}

Write-Output ("BEFORE: {0}" -f (Get-Status $mi00))

Write-Output 'Disabling MI_00...'
pnputil /disable-device $mi00 2>&1 | ForEach-Object { Write-Output $_ }
Start-Sleep -Seconds 3
Write-Output ("AFTER DISABLE: {0}" -f (Get-Status $mi00))

Write-Output 'Enabling MI_00...'
pnputil /enable-device $mi00 2>&1 | ForEach-Object { Write-Output $_ }
Start-Sleep -Seconds 8

Write-Output ("AFTER ENABLE: {0}" -f (Get-Status $mi00))

Write-Output ''
Write-Output 'Child HID nodes for MI_00 after re-enable:'
$found = 0
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\HID' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'VID_05AC&PID_0324&MI_00' } | ForEach-Object {
    $found++
    Write-Output "  NODE: $($_.Name)"
    Get-ChildItem $_.PSPath -ErrorAction SilentlyContinue | ForEach-Object { Write-Output "    INSTANCE: $($_.Name)" }
}
if (-not $found) { Write-Output '  (still no child HID nodes)' }

Write-Output ''
Write-Output 'DONE'
