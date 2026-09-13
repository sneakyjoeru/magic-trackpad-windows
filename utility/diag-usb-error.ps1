# diag-usb-error.ps1 - diagnose the "USB Input Device" (MI_00) error on the Magic Trackpad
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File diag-usb-error.ps1

$ErrorActionPreference = 'Continue'

function Dump-RegNode([string]$path) {
    if (-not (Test-Path $path)) { Write-Output "(not found: $path)"; return }
    Write-Output "=== $path ==="
    Get-ItemProperty $path | Format-List | Write-Output
    foreach ($child in (Get-ChildItem $path).Name) {
        $ck = Join-Path $path $child
        Write-Output "  --- child: $child ---"
        Get-ItemProperty $ck | Format-List | Write-Output
    }
}

Write-Output '########## 1. PnP inventory (trackpad-related) ##########'
Get-CimInstance Win32_PnPEntity | Where-Object { $_.DeviceID -match '05AC|CC56856AC25E|MS_BTH' } | ForEach-Object {
    Write-Output ("{0,-58} | {1,-40} | Status={2,-6} CfgErr={3,-4} Service={4}" -f $_.DeviceID, $_.Name, $_.Status, $_.ConfigManagerErrorCode, $_.Service)
}

Write-Output ''
Write-Output '########## 2. Registry: erroring MI_00 node ##########'
Dump-RegNode 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB\VID_05AC&PID_0324&MI_00\7&17F26F02&0&0000'

Write-Output ''
Write-Output '########## 3. Registry: composite device node ##########'
Dump-RegNode 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB\VID_05AC&PID_0324\CC2HH100J4A0000502'

Write-Output ''
Write-Output '########## 4. Services (UMDF / HID / PnP related) ##########'
Get-CimInstance Win32_Service | Where-Object { $_.Name -match 'mshidumdf|AmtPtp|WUDF' } | ForEach-Object {
    Write-Output ("{0,-25} State={1,-10} StartMode={2}" -f $_.Name, $_.State, $_.StartMode)
}

Write-Output ''
Write-Output '########## 5. System event log (last 12h, USB/HID/WUDF/trackpad related) ##########'
$cutoff = (Get-Date).AddHours(-12)
try {
    $events = Get-EventLog -LogName System -Newest 500
} catch {
    Write-Output "Get-EventLog failed: $_"
    $events = @()
}
$hits = 0
foreach ($e in $events) {
    if ($e.TimeWritten -le $cutoff) { continue }
    if ($e.Message -match '05AC|trackpad|AmtPtp|WUDF|HID|USB' -or $e.Source -match 'USB|PnP|WUDF|HID|Kernel-PnP|Service Control Manager') {
        $hits++
        Write-Output ('{0} | {1} | {2} | ID={3}' -f $e.TimeWritten, $e.EntryType, $e.Source, $e.EventID)
        $msg = ($e.Message -replace "`r`n", ' ')
        if ($msg.Length -gt 350) { $msg = $msg.Substring(0,350) + '...' }
        Write-Output "    $msg"
    }
}
if ($hits -eq 0) { Write-Output '(no matching events in window)' }

Write-Output ''
Write-Output '########## 6. USB topology (parent chain of composite device) ##########'
$devs = @{}
Get-CimInstance Win32_PnPEntity | ForEach-Object { $devs[$_.DeviceID] = $_ }
$id = 'USB\VID_05AC&PID_0324\CC2HH100J4A0000502'
$i = 0
while ($id -and $i -lt 8) {
    $d = $devs[$id]
    if (-not $d) { Write-Output ("  [{0}] {1} (no PnP record)" -f $i, $id); break }
    Write-Output ("  [{0}] {1} | {2} | Class={3} | Status={4} CfgErr={5}" -f $i, $d.DeviceID, $d.Name, $d.PNPClass, $d.Status, $d.ConfigManagerErrorCode)
    $id = $d.Parent
    $i++
}

Write-Output ''
Write-Output 'DONE'
