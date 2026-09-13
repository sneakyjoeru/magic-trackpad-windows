$ErrorActionPreference = 'Continue'
Write-Host '=== 1. TRACKPAD-RELATED PNP DEVICES (status + IDs) ==='
$all = @(Get-CimInstance Win32_PnPEntity)
$all | Where-Object { $_.DeviceID -match 'BTH|05AC|27A7' -or $_.Name -match 'Magic|Trackpad' } |
    ForEach-Object {
        Write-Host ("DEV={0}" -f $_.DeviceID)
        Write-Host ("  NAME={0} | STATUS={1} | CONFIGCODE={2}" -f $_.Name, $_.Status, $_.ConfigManagerErrorCode)
        $hwids = @()
        try {
            $k = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $_.DeviceID.Split('\')[0]
            # read HardwareIDs from the device's registry key
            $parts = $_.DeviceID -split '\\'
            if ($parts.Count -ge 2) {
                $devKey = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $parts[0] + '\' + $parts[1]
                $key = Get-Item $devKey -ErrorAction SilentlyContinue
                if ($key) {
                    $hw = $key.GetValue('HardwareID')
                    if ($hw) { $hwids += $hw }
                }
            }
        } catch {}
        if ($hwids.Count) { Write-Host ("  HWIDS: {0}" -f ($hwids -join ', ')) }
        Write-Host ''
    }

Write-Host '=== 2. DRIVER-RELATED EVENT LOG (last 30 min, last 15) ==='
Get-EventLog -LogName System -After (Get-Date).AddMinutes(-30) -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -match 'trackpad|AmtPtp|mshidumdf|WUDF|BTH|05AC|27A7' } |
    Select-Object -First 15 |
    ForEach-Object {
        Write-Host ("[{0}] {1} (source={2})" -f $_.TimeWritten, $_.EntryType, $_.Source)
        Write-Host ("  {0}" -f $_.Message.Substring(0, [Math]::Min(300, $_.Message.Length)))
        Write-Host ''
    }

Write-Host '=== 3. UMDF SERVICE STATE ==='
$svc = Get-CimInstance Win32_Service | Where-Object { $_.Name -eq 'mshidumdf' -or $_.Name -like '*AmtPtp*' }
foreach ($s in $svc) { Write-Host ("SERVICE {0} ({1}): State={2} StartMode={3}" -f $s.Name, $s.DisplayName, $s.State, $s.StartMode) }

Write-Host '=== 4. WUDFHost PROCESSES ==='
Get-Process WUDFHost -ErrorAction SilentlyContinue | ForEach-Object { Write-Host ("WUDFHost PID={0} Started={1}" -f $_.Id, $_.StartTime) }

Write-Host 'DIAG_DONE'
