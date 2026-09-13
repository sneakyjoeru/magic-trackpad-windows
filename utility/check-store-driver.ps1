$ErrorActionPreference = 'Continue'
$dirs = @(Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Directory -Filter 'amtptpdevice.inf_amd64_*')
foreach ($d in $dirs) {
    $dll = Join-Path $d.FullName 'AmtPtpDeviceUsbUm.dll'
    if (Test-Path $dll) {
        $f = Get-Item $dll
        Write-Host ("STORE_DIR: {0}" -f $d.FullName)
        Write-Host ("DLL: {0}" -f $f.FullName)
        Write-Host ("FILE_VERSION: {0}" -f $f.VersionInfo.FileVersion)
        Write-Host ("PRODUCT_VERSION: {0}" -f $f.VersionInfo.ProductVersion)
        Write-Host ("LAST_WRITE: {0}" -f $f.LastWriteTime)
        Write-Host '---'
    }
}
# Also show which package the MI_01 device is currently bound to
$dev = Get-CimInstance Win32_PnPEntity | Where-Object { $_.DeviceID -match 'MI_01' -and $_.DeviceID -match '05AC' } | Select-Object -First 1
if ($dev) {
    Write-Host ("DEVICE: {0}" -f $dev.DeviceID)
    Write-Host ("STATUS: {0}" -f $dev.Status)
}
Write-Host 'CHECK_DONE'
