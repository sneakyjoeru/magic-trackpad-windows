# diag-usb-error2.ps1 - deep dive: MI_00 Device Parameters, event log, services
$ErrorActionPreference = 'Continue'

Write-Output '########## 1. MI_00 Device Parameters (reg query) ##########'
reg query 'HKLM\SYSTEM\CurrentControlSet\Enum\USB\VID_05AC&PID_0324&MI_00\7&17F26F02&0&0000\Device Parameters' /s 2>&1

Write-Output ''
Write-Output '########## 2. MI_00 Properties (reg query) ##########'
reg query 'HKLM\SYSTEM\CurrentControlSet\Enum\USB\VID_05AC&PID_0324&MI_00\7&17F26F02&0&0000\Properties' 2>&1

Write-Output ''
Write-Output '########## 3. MI_01 Device Parameters (compare, known-good) ##########'
reg query 'HKLM\SYSTEM\CurrentControlSet\Enum\USB\VID_05AC&PID_0324&MI_01\7&17F26F02&0&0001\Device Parameters' /s 2>&1

Write-Output ''
Write-Output '########## 4. Services via sc ##########'
sc.exe query mshidumdf 2>&1
sc.exe qfailure mshidumdf 2>&1
Write-Output '--- WUDFSvcHost ---'
sc.exe query WUDFSvcHost 2>&1

Write-Output ''
Write-Output '########## 5. Event log: Kernel-PnP / USB / WUDF / HID (last 24h, all types) ##########'
$cutoff = (Get-Date).AddHours(-24)
try {
    $events = Get-EventLog -LogName System -Newest 1000
} catch { Write-Output "Get-EventLog failed: $_"; $events = @() }
$hits = 0
foreach ($e in $events) {
    if ($e.TimeWritten -le $cutoff) { continue }
    $src = $e.Source; $msg = $e.Message
    if (($e.EntryType -ne 'Information') -and ($src -match 'PnP|USB|WUDF|HID|Service Control' -or $msg -match '05AC|trackpad|AmtPtp|WUDF|mshidumdf|HID|USB')) {
        $hits++
        Write-Output ('{0} | {1} | {2} | ID={3}' -f $e.TimeWritten, $e.EntryType, $src, $e.EventID)
        $m = ($msg -replace "`r`n", ' ')
        if ($m.Length -gt 400) { $m = $m.Substring(0,400) + '...' }
        Write-Output "    $m"
    }
}
if ($hits -eq 0) { Write-Output '(no non-Information events matched in window)' }

Write-Output ''
Write-Output '########## 6. WMI Win32_LogEvent (last 50, all logs) ##########'
try {
    Get-CimInstance Win32_LogEvent -Filter "EventLog='System'" | Select-Object -First 50 | ForEach-Object {
        $t = [DateTime]::FromFileTime($_.Timestamp)
        if ($t -ge $cutoff) {
            Write-Output ("{0} | Type={1} | Src={2} | ID={3}" -f $t, $_.EventType, $_.SourceName, $_.EventID)
            $m = ($_.Message -replace "`r`n", ' ')
            if ($m.Length -gt 300) { $m = $m.Substring(0,300) + '...' }
            Write-Output "    $m"
        }
    }
} catch { Write-Output "Win32_LogEvent failed: $_" }

Write-Output ''
Write-Output '########## 7. WUDFHost processes ##########'
Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'WUDF' } | ForEach-Object {
    Write-Output ("{0} PID={1} Started={2}" -f $_.Name, $_.ProcessId, $_.CreationDate)
}

Write-Output ''
Write-Output 'DONE'
