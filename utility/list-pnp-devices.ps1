$ErrorActionPreference = 'Continue'
$all = @(Get-CimInstance Win32_PnPEntity)
Write-Host ("TOTAL_PNP_ENTITIES: {0}" -f $all.Count)
Write-Host '--- TRACKPAD / APPLE USB MATCHES ---'
$matches = $all | Where-Object { $_.DeviceID -match '05AC|27A7' -or $_.Name -match 'Magic|Trackpad' }
if ($matches) {
    $matches | ForEach-Object { Write-Host ("DEV={0} | STATUS={1} | NAME={2}" -f $_.DeviceID, $_.Status, $_.Name) }
} else {
    Write-Host 'NONE'
}
Write-Host 'LIST_DONE'
