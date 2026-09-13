# diag-usb-error3.ps1 - timestamp the MI_00 error, inspect child HID nodes, raw SetupAPI problem codes
$ErrorActionPreference = 'Continue'

Write-Output '########## 1. Timestamps on MI_00 node ##########'
$p = 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB\VID_05AC&PID_0324&MI_00\7&17F26F02&0&0000'
$props = Get-ItemProperty $p
function Decode-FileTime($v) {
    if ($null -eq $v) { return $null }
    if ($v -is [byte[]]) { if ($v.Length -lt 8) { return $null }; return [DateTime]::FromFileTime([BitConverter]::ToUInt64($v, 0)) }
    if ($v -is [long]) { return [DateTime]::FromFileTime([uint64]$v) }
    return $null
}
$lqt = Decode-FileTime $props.PSObject.Properties['LastQueryTime'].Value
if ($lqt) { Write-Output ("LastQueryTime: {0}" -f $lqt) } else { Write-Output 'LastQueryTime: (absent)' }
Write-Output ("ConfigFlags  : {0}" -f $props.ConfigFlags)
$pn = $props.PSObject.Properties['ProblemNumber']
if ($pn) { Write-Output ("ProblemNumber: {0}" -f $pn.Value) } else { Write-Output 'ProblemNumber: (absent)' }

Write-Output ''
Write-Output '########## 2. Child HID nodes under MI_00 ##########'
$found = 0
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\HID' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'MI_00' } | ForEach-Object {
    $found++
    Write-Output "NODE: $($_.Name)"
    Get-ChildItem $_.PSPath -ErrorAction SilentlyContinue | ForEach-Object {
        $inst = $_.PSPath
        Write-Output "  INSTANCE: $($_.Name)"
        try {
            $ip = Get-ItemProperty $inst -ErrorAction Stop
            Write-Output ("    Status: {0}  ConfigManagerErrorCode: {1}" -f $ip.Status, $ip.ConfigManagerErrorCode)
            $lqt = Decode-FileTime $ip.PSObject.Properties['LastQueryTime'].Value
            if ($lqt) { Write-Output ("    LastQueryTime: {0}" -f $lqt) }
        } catch { Write-Output "    (no props: $_)" }
    }
}
if (-not $found) { Write-Output '(no HID child nodes under MI_00)' }

Write-Output ''
Write-Output '########## 3. pnputil enumerate-device (05AC blocks) ##########'
$out = pnputil /enumerate-device 2>&1
$lines = $out -split "`r?`n"
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '05AC') {
        $end = [Math]::Min($i + 14, $lines.Count - 1)
        for ($j = $i; $j -le $end; $j++) { Write-Output $lines[$j] }
        Write-Output '----------------------------------------'
    }
}

Write-Output ''
Write-Output 'DONE'
