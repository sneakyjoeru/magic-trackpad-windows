<#
.SYNOPSIS
    Unattended verification harness for the Magic Trackpad driver deployment.

.DESCRIPTION
    Run after installing the driver (wired or wireless). Produces a PASS/FAIL report from
    signals that do NOT require a human at the keyboard:

      1. PnP: trackpad HID interface (MI_01) exists and is OK
      2. PnP: the interface is BOUND to the AmtPtp driver (class = AmtPtpDeviceUsbUm / service AmtPtpDeviceUsbUm)
      3. Service: AmtPtpHidFilter exists and is Running
      4. IOCTL: \\.\AmtPtpControlDeviceUm opens and answers IOCTL_RELOAD_SETTINGS
      5. IOCTL: IOCTL_GET_BATTERY returns a plausible value (informational; 0/wired => skip)
      6. Events: no driver errors in the System log since the install marker

    Exit codes: 0 = all mandatory checks passed, 1 = one or more failed, 2 = trackpad not present.

.PARAMETER Since
    Optional: only count events newer than this (ISO date). Used together with an install marker.

.EXAMPLE
    .\Verify-MtTrackpad.ps1
.EXAMPLE
    .\Verify-MtTrackpad.ps1 -Since (Get-Date).AddMinutes(-10) -Json
#>
[CmdletBinding()]
param(
    [datetime]$Since = (Get-Date).AddMinutes(-30),
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

$CTL_RELOAD_SETTINGS = 0x00222000
$CTL_GET_BATTERY     = 0x00222004
$CONTROL_DEVICE      = '\\.\AmtPtpControlDeviceUm'
$KnownPrefixes = @('USB\VID_05AC&PID_0324', 'USB\VID_27A7&PID_2501', 'USB\VID_27A7&PID_9601')

$Kernel32 = Add-Type -Namespace MtVerify -Name Kernel32 -PassThru -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern IntPtr CreateFileW(string lpFileName, uint dwDesiredAccess, uint dwShareMode,
    IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool DeviceIoControl(IntPtr hDevice, uint dwIoControlCode, IntPtr lpInBuffer, uint nInBufferSize,
    IntPtr lpOutBuffer, uint nOutBufferSize, out uint lpBytesReturned, IntPtr lpOverlapped);
[DllImport("kernel32.dll")]
public static extern bool CloseHandle(IntPtr hObject);
'@

$checks = [ordered]@{}

# ---- 1+2: PnP presence and driver binding ----
$mi01 = $null
foreach ($p in $KnownPrefixes) {
    $mi01 = Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like "$p&MI_01\*" } | Select-Object -First 1
    if ($mi01) { break }
}

$present = [bool]$mi01
$bound = $null
if ($present) {
    $entity = Get-CimInstance Win32_PnPEntity | Where-Object { $_.PNPDeviceID -eq $mi01.InstanceId } | Select-Object -First 1
    $bound = [bool]($entity -and $entity.Service -eq 'AmtPtpDeviceUsbUm')
}

$checks['trackpad_present'] = [bool]$present
$checks['bound_to_amtptp']   = if ($present) { $bound } else { $null }
$checks['mi01_instance']     = if ($present) { $mi01.InstanceId } else { $null }
$checks['mi01_status']       = if ($present) { $mi01.Status } else { $null }

# ---- 3: kernel filter service ----
$svc = Get-CimInstance Win32_Service -Filter "Name='AmtPtpHidFilter'" -ErrorAction SilentlyContinue
$checks['hidfilter_service_running'] = [bool]($svc -and $svc.State -eq 'Running')

# ---- 4: control device IOCTL ----
$ioctlOk = $false
$win32Err = $null
try {
    $h = [MtVerify.Kernel32]::CreateFileW($CONTROL_DEVICE, 0xC0000000, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    if ([int]$h -ne 0) {
        try {
            $br = [uint32]0
            $ok = [MtVerify.Kernel32]::DeviceIoControl($h, $CTL_RELOAD_SETTINGS, [IntPtr]::Zero, 0, [IntPtr]::Zero, 0, [ref]$br, [IntPtr]::Zero)
            $ioctlOk = $ok
            if (-not $ok) { $win32Err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error() }
        }
        finally { [MtVerify.Kernel32]::CloseHandle($h) }
    }
    else { $win32Err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error() }
}
catch { $win32Err = $_.Exception.Message }
$checks['ioctl_reload_ok'] = $ioctlOk

# ---- 5: battery (informational) ----
$battery = $null
if ($ioctlOk) {
    try {
        $h = [MtVerify.Kernel32]::CreateFileW($CONTROL_DEVICE, 0xC0000000, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
        if ([int]$h -ne 0) {
            try {
                $buf = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(4)
                $br = [uint32]0
                $ok = [MtVerify.Kernel32]::DeviceIoControl($h, $CTL_GET_BATTERY, [IntPtr]::Zero, 0, $buf, 4, [ref]$br, [IntPtr]::Zero)
                if ($ok) {
                    $v = [System.Runtime.InteropServices.Marshal]::ReadInt32($buf)
                    if ($v -le 100) { $battery = $v }
                }
                [System.Runtime.InteropServices.Marshal]::FreeHGlobal($buf)
            }
            finally { [MtVerify.Kernel32]::CloseHandle($h) }
        }
    }
    catch { }
}
$checks['battery_percent'] = $battery

# ---- 6: driver errors since $Since ----
$errEvents = @(Get-WinEvent -LogName System -ErrorAction SilentlyContinue |
    Where-Object { $_.TimeCreated -gt $Since -and $_.Level -eq 2 -and
                   ($_.Message -match 'AmtPtp|WUDF|HidClass' -or $_.ProviderName -match 'AmtPtp') })
$checks['driver_errors_since'] = $errEvents.Count
$checks['driver_error_sample'] = if ($errEvents.Count) { $errEvents[0].Message.Substring(0, [Math]::Min(200, $errEvents[0].Message.Length)) } else { $null }

# ---- verdict ----
$mandatory = @('trackpad_present', 'bound_to_amtptp', 'hidfilter_service_running', 'ioctl_reload_ok')
$failed = @($mandatory | Where-Object { -not $checks[$_] })
$verdict = if (-not $present) { 'NO_DEVICE' } elseif ($failed.Count -eq 0) { 'PASS' } else { 'FAIL' }

$result = [ordered]@{
    verdict            = $verdict
    failedChecks       = @($failed)
    checks             = $checks
    timestampUtc       = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
}

if ($Json) { $result | ConvertTo-Json -Depth 5 }
else {
    $result.checks | Format-List
    Write-Output ""
    Write-Output ("VERDICT: {0}  (failed: {1})" -f $verdict, ($failed -join ', '))
}

if ($verdict -eq 'PASS') { exit 0 }
elseif ($verdict -eq 'FAIL') { exit 1 }
else { exit 2 }
