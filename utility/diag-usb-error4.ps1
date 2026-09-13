# diag-usb-error4.ps1 - pinpoint the MI_00 error: event log since boot, orphaned nodes, raw pnputil
$ErrorActionPreference = 'Continue'

Write-Output '########## 1. System uptime / boot time ##########'
$os = Get-CimInstance Win32_OperatingSystem
Write-Output ("BootTime: {0}" -f $os.LocalDateTime)

Write-Output ''
Write-Output '########## 2. ALL System events since boot (HID/USB/PnP/WUDF/05AC/trackpad) ##########'
$cutoff = [DateTime]::Parse($os.LocalDateTime)
try {
    $events = Get-EventLog -LogName System -Newest 2000
} catch { Write-Output "Get-EventLog failed: $_"; $events = @() }
$hits = 0
foreach ($e in $events) {
    if ($e.TimeWritten -lt $cutoff) { continue }
    $src = $e.Source; $msg = $e.Message
    $match = ($src -match 'PnP|USB|WUDF|HID|Kernel-PnP|Plug and Play' ) -or ($msg -match '05AC|trackpad|AmtPtp|WUDF|mshidumdf|HID|USB Input|composite')
    if ($match) {
        $hits++
        Write-Output ('{0} | {1} | {2} | ID={3}' -f $e.TimeWritten, $e.EntryType, $src, $e.EventID)
        $m = ($msg -replace "`r`n", ' ')
        if ($m.Length -gt 500) { $m = $m.Substring(0,500) + '...' }
        Write-Output "    $m"
    }
}
if ($hits -eq 0) { Write-Output '(no matching events since boot)' }

Write-Output ''
Write-Output '########## 3. Orphaned HID nodes for VID_05AC&PID_0324&MI_00 ##########'
$found = 0
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\HID' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'VID_05AC&PID_0324' } | ForEach-Object {
    $found++
    Write-Output "NODE: $($_.Name)"
    Get-ChildItem $_.PSPath -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Output "  INSTANCE: $($_.Name)"
    }
}
if (-not $found) { Write-Output '(no HID nodes for VID_05AC&PID_0324 at all)' }

Write-Output ''
Write-Output '########## 4. Raw pnputil enumerate-device (raw, first 60 lines) ##########'
$raw = pnputil /enumerate-device 2>&1
$rl = $raw -split "`r?`n"
for ($i = 0; $i -lt [Math]::Min(60, $rl.Count); $i++) { Write-Output $rl[$i] }
Write-Output ("(total lines: {0})" -f $rl.Count)

Write-Output ''
Write-Output '########## 5. pnputil enumerate-device: lines mentioning 05AC (case-insens) ##########'
$hits2 = 0
for ($i = 0; $i -lt $rl.Count; $i++) {
    if ($rl[$i] -match '05AC') {
        $hits2++
        Write-Output $rl[$i]
    }
}
if (-not $hits2) { Write-Output '(no 05AC lines in pnputil output)' }

Write-Output ''
Write-Output 'DONE'
