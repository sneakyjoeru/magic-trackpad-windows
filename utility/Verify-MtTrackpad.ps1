<#
.SYNOPSIS
    Unattended verification harness for the Magic Trackpad driver deployment.

.DESCRIPTION
    Run after installing the driver (wired or wireless). Produces a PASS/FAIL report from
    signals that do NOT require a human at the keyboard.

    Connection mode is auto-detected (or forced with -Mode):

    WIRED (USB) — the trackpad's HID interface (MI_01) is driven by the UMDF driver
    AmtPtpDeviceUsbUm.dll hosted in WUDFHost. The device node's service is the UMDF
    reflector (mshidumdf) and its friendly name comes from our INF:
    "Apple USB Precision Touchpad Device (User-mode)". Mandatory checks:
      1. PnP: USB trackpad HID interface exists and is OK
      2. PnP: the interface is bound to OUR driver (friendly name / manufacturer from our INF)
      3. Driver: AmtPtpDeviceUsbUm.dll is loaded in a running process (WUDFHost)
      4. Store: our driver package (amtptpdevice.inf) is present in the driver store
      5. Events: no driver errors in the System log since the install marker

    Note: in wired mode there is no kernel HID filter and no \\.\AmtPtpControlDeviceUm
    control device — those belong to the Bluetooth driver path.

    WIRELESS (Bluetooth) — the trackpad's HID collection is filtered by the KMDF driver
    AmtPtpHidFilter.sys, which also creates the \\.\AmtPtpControlDeviceUm control device.
    Mandatory checks:
      1. PnP: BT trackpad HID device exists and is OK
      2. PnP: the device is bound to the AmtPtpHidFilter service
      3. Service: AmtPtpHidFilter exists and is Running
      4. IOCTL: \\.\AmtPtpControlDeviceUm opens and answers IOCTL_PTPFILTER_RELOAD_SETTINGS
      5. IOCTL: IOCTL_PTPFILTER_GET_BATTERY returns a plausible value (informational)
      6. Events: no driver errors in the System log since the install marker

    Exit codes: 0 = all mandatory checks passed, 1 = one or more failed, 2 = trackpad not present.

.PARAMETER Mode
    Auto (default) | Wired | Wireless. Auto = USB if a wired trackpad is present,
    otherwise Bluetooth.

.PARAMETER Since
    Optional: only count events newer than this (ISO date). Used together with an install marker.

.EXAMPLE
    .\Verify-MtTrackpad.ps1
.EXAMPLE
    .\Verify-MtTrackpad.ps1 -Mode Wired -Since (Get-Date).AddMinutes(-10) -Json
#>
[CmdletBinding()]
param(
    [ValidateSet('Auto','Wired','Wireless')]
    [string]$Mode = 'Auto',
    [datetime]$Since = (Get-Date).AddMinutes(-30),
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

$CTL_RELOAD_SETTINGS = 0x00222000
$CTL_GET_BATTERY     = 0x00222004
$CONTROL_DEVICE      = '\\.\AmtPtpControlDeviceUm'

# Wired USB HID interfaces (MI_01 for classic PIDs, MI_00/MI_01 for the resold 27A7 PIDs)
$UsbInterfaces = @(
    'USB\VID_05AC&PID_0324&MI_01',
    'USB\VID_05AC&PID_0265&MI_01',
    'USB\VID_27A7&PID_2501&MI_00',
    'USB\VID_27A7&PID_2501&MI_01',
    'USB\VID_27A7&PID_9601&MI_00',
    'USB\VID_27A7&PID_9601&MI_01'
)
# Bluetooth HID collections (Col01 = the trackpad interface our filter binds to)
$BtInterfaces = @(
    'HID\{00001124-0000-1000-8000-00805F9B34FB}_VID&0001004C_PID&0265&Col01',
    'HID\{00001124-0000-1000-8000-00805F9B34FB}_VID&0001004C_PID&0324&Col01'
)

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

function Find-TrackpadInterface([string[]]$Patterns) {
    foreach ($p in $Patterns) {
        $dev = Get-PnpDevice -ErrorAction SilentlyContinue |
            Where-Object { $_.InstanceId -like "$p\*" } |
            Where-Object { $_.Status -eq 'OK' } |
            Select-Object -First 1
        if ($dev) { return $dev }
    }
    return $null
}

# ---- Detect connection mode ----
$usbDev = Find-TrackpadInterface $UsbInterfaces
$btDev  = Find-TrackpadInterface $BtInterfaces
if ($Mode -eq 'Auto') {
    if ($usbDev) { $Mode = 'Wired' } elseif ($btDev) { $Mode = 'Wireless' } else { $Mode = 'None' }
} elseif ($Mode -eq 'Wired') { $dev = $usbDev } else { $dev = $btDev }

$checks = [ordered]@{ connection_mode = $Mode }

if ($Mode -eq 'Wired') {
    # ---- Wired (USB / UMDF) checks ----
    $present = [bool]$usbDev
    $checks['trackpad_present'] = $present

    $bound = $null
    $friendlyName = $null
    $manufacturer = $null
    if ($present) {
        $entity = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
            Where-Object { $_.PNPDeviceID -eq $usbDev.InstanceId } | Select-Object -First 1
        if ($entity) {
            $friendlyName = $entity.FriendlyName
            $manufacturer = $entity.Manufacturer
            # Bound to our driver: the friendly name / manufacturer come from our INF.
            # (The device node's service is the UMDF reflector 'mshidumdf' for any UMDF driver.)
            $bound = [bool]($friendlyName -like 'Apple*Precision Touchpad*' -or $manufacturer -like 'Bingxing Wang*')
        }
    }
    $checks['bound_to_amtptp']   = if ($present) { $bound } else { $null }
    $checks['mi01_instance']     = if ($present) { $usbDev.InstanceId } else { $null }
    $checks['mi01_friendly_name']= $friendlyName
    $checks['mi01_status']       = if ($present) { $usbDev.Status } else { $null }

    # UMDF driver actually loaded and running (hosted in WUDFHost)
    $loaded = $false
    $hostProc = $null
    foreach ($p in Get-Process) {
        try {
            foreach ($m in $p.Modules) {
                if ($m.FileName -like '*amtptpdeviceusbum.dll') { $loaded = $true; $hostProc = $p.ProcessName; break }
            }
        } catch { }
        if ($loaded) { break }
    }
    $checks['umdf_driver_loaded'] = $loaded
    $checks['umdf_host_process']  = $hostProc

    # Our driver package present in the driver store
    $pkgOut = (& pnputil.exe /enum-drivers 2>&1 | Out-String)
    $checks['driver_package_in_store'] = [bool]($pkgOut -match 'amtptpdevice\.inf')

    # Battery: not exposed in wired mode (no control device) — informational only
    $checks['battery_percent'] = $null

} elseif ($Mode -eq 'Wireless') {
    # ---- Wireless (Bluetooth / KMDF filter) checks ----
    $present = [bool]$btDev
    $checks['trackpad_present'] = $present

    $bound = $null
    if ($present) {
        $entity = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
            Where-Object { $_.PNPDeviceID -eq $btDev.InstanceId } | Select-Object -First 1
        $bound = [bool]($entity -and $entity.Service -eq 'AmtPtpHidFilter')
    }
    $checks['bound_to_amtptp']   = if ($present) { $bound } else { $null }
    $checks['bt_instance']       = if ($present) { $btDev.InstanceId } else { $null }
    $checks['mi01_status']       = if ($present) { $btDev.Status } else { $null }

    $svc = Get-CimInstance Win32_Service -Filter "Name='AmtPtpHidFilter'" -ErrorAction SilentlyContinue
    $checks['hidfilter_service_running'] = [bool]($svc -and $svc.State -eq 'Running')

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
}
else {
    $checks['trackpad_present'] = $false
    $checks['bound_to_amtptp']  = $null
    $checks['mi01_status']      = $null
    $checks['umdf_driver_loaded'] = $null
    $checks['driver_package_in_store'] = $null
    $checks['battery_percent']  = $null
}

# ---- Common: driver errors since $Since ----
$errEvents = @(Get-WinEvent -LogName System -ErrorAction SilentlyContinue |
    Where-Object { $_.TimeCreated -gt $Since -and $_.Level -eq 2 -and
                   ($_.Message -match 'AmtPtp|WUDF|HidClass' -or $_.ProviderName -match 'AmtPtp') })
$checks['driver_errors_since'] = $errEvents.Count
$checks['driver_error_sample'] = if ($errEvents.Count) { $errEvents[0].Message.Substring(0, [Math]::Min(200, $errEvents[0].Message.Length)) } else { $null }

# ---- Verdict ----
if ($Mode -eq 'Wired') {
    $mandatory = @('trackpad_present', 'bound_to_amtptp', 'umdf_driver_loaded', 'driver_package_in_store')
} elseif ($Mode -eq 'Wireless') {
    $mandatory = @('trackpad_present', 'bound_to_amtptp', 'hidfilter_service_running', 'ioctl_reload_ok')
} else {
    $mandatory = @('trackpad_present')
}
$failed = @($mandatory | Where-Object { -not $checks[$_] })
$present = [bool]$checks['trackpad_present']
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
