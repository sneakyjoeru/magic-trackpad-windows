<#
.SYNOPSIS
    Magic Trackpad (Apple) setup & control utility for Windows.

.DESCRIPTION
    Companion utility for the MagicTrackpad2ForWindows driver (AmtPtpDeviceUsbUm + AmtPtpHidFilter).
    Works headless (scheduled tasks / SSH) for everything except the Bluetooth pairing UI.

    Supported Apple Magic Trackpad USB-C devices:
      USB\VID_05AC&PID_0324  (Magic Trackpad 2, USB-C, 2024)
      USB\VID_27A7&PID_2501 / 0x9601  (alternate VID revisions)
    Bluetooth: device IDs are captured with "wireless scan" after pairing, then added to the INF.

.PARAMETER Action
    install    Install the driver package (driver dir must contain AMD64\AmtPtpDevice.inf, .dll, .sys, .cat, .cer)
    uninstall  Remove driver packages and (optionally) the device instances
    status     Show device / driver / service / control-device state
    settings   Show current haptic & gesture settings (registry)
    configure  Apply haptic & gesture settings, then reload the driver
    battery    Query battery level via IOCTL (meaningful when connected via Bluetooth)
    reload     Ask the driver to reload settings (IOCTL_RELOAD_SETTINGS) + restart the device
    wireless   List Bluetooth candidates / start pairing UI / report hardware IDs for INF extension
    rotate     Rotate the trackpad (0 | 90 | 180 | -90 degrees) and reload the driver
    tray       Stay resident in the notification area with a rotation quick-switch menu
    autostart  Install / remove / report the logon task that starts "tray" elevated (no UAC prompt)

.PARAMETER Degrees
    Rotation for the rotate action: 0, 90, 180, 270, -90 (270) or 360 (0).

.PARAMETER On
    autostart: install (or replace) the "start the tray utility at logon" scheduled task.

.PARAMETER Off
    autostart: remove that scheduled task.

.EXAMPLE
    .\MtTrackpad.ps1 install        # auto-detects the driver folder in the release archive
    .\MtTrackpad.ps1 install -DriverDir C:\MtTrackpad\Driver
.EXAMPLE
    .\MtTrackpad.ps1 configure -Feedback medium -Silent -StopPressure 50 -Palm on
.EXAMPLE
    .\MtTrackpad.ps1 status -Json
.EXAMPLE
    .\MtTrackpad.ps1 battery
.EXAMPLE
    .\MtTrackpad.ps1 wireless -Pair
.EXAMPLE
    .\MtTrackpad.ps1 rotate -Degrees -90
.EXAMPLE
    .\MtTrackpad.ps1 autostart -On        # then: .\MtTrackpad.ps1 tray
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('install', 'uninstall', 'status', 'settings', 'configure', 'battery', 'reload', 'wireless', 'rotate', 'tray', 'autostart')]
    [string]$Action,

    # --- install / uninstall ---
    [string]$DriverDir,
    [switch]$Force,

    # --- configure ---
    [ValidateSet('light', 'medium', 'firm', 'maximum', 'disabled')]
    [string]$Feedback,
    [switch]$Silent,
    [switch]$NoSilent,
    [int]$StopPressure,   # >= 0 sets pressure threshold; -1 clears
    [int]$StopSize,       # >= 0 sets size threshold; -1 clears
    [ValidateSet('on', 'off', '')] [string]$Palm,
    [ValidateSet('on', 'off', '')] [string]$IgnoreButton,
    [ValidateSet('on', 'off', '')] [string]$IgnoreNear,

    # --- status / wireless ---
    [switch]$Json,
    [switch]$Pair,

    # --- rotate ---
    [ValidateSet('0', '90', '180', '270', '-90', '360')]
    [string]$Degrees,

    # --- autostart ---
    [switch]$On,
    [switch]$Off
)

$ErrorActionPreference = 'Stop'

# Absolute path of this script, needed to register the logon task.
$script:SelfPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
# Name of the scheduled task that starts the tray utility at logon.
$script:AutostartTaskName = 'MtTrackpadTray'

# ============================= Constants =============================
$script:CTL_RELOAD_SETTINGS = 0x00222000   # CTL_CODE(FILE_DEVICE_UNKNOWN=0x22, 0x800, METHOD_BUFFERED, FILE_ANY_ACCESS)
$script:CTL_GET_BATTERY     = 0x00222004   # CTL_CODE(FILE_DEVICE_UNKNOWN=0x22, 0x801, METHOD_BUFFERED, FILE_ANY_ACCESS)
$script:CONTROL_DEVICE      = '\\.\AmtPtpControlDeviceUm'

$script:WUDF_PARAMS  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WUDF\Services\AmtPtpDeviceUsbUm\Parameters'
$script:SVC_PARAMS   = 'HKLM:\SYSTEM\CurrentControlSet\Services\AmtPtpHidFilter\Parameters'

# Known wired hardware IDs (interface level). Extend here when wireless IDs are captured.
$script:KnownUsbInstances = @(
    'USB\VID_05AC&PID_0324',     # Magic Trackpad 2 USB-C (2024)
    'USB\VID_27A7&PID_2501',
    'USB\VID_27A7&PID_9601'
)

# Haptic feedback presets (DWORD values, same encoding as the upstream control panel)
$script:FeedbackPresets = @{
    light    = @{ Click = 0x040415; Release = 0x000010 }
    medium   = @{ Click = 0x060617; Release = 0x000014 }
    firm     = @{ Click = 0x08081e; Release = 0x020218 }
    maximum  = @{ Click = 0xFFFFFF; Release = 0xFFFFFF }
    disabled = @{ Click = 0x000000; Release = 0x000000 }
}

# ============================= P/Invoke =============================
$script:Kernel32 = Add-Type -Namespace MtTrackpad -Name Kernel32 -PassThru -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern IntPtr CreateFileW(string lpFileName, uint dwDesiredAccess, uint dwShareMode,
    IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool DeviceIoControl(IntPtr hDevice, uint dwIoControlCode, IntPtr lpInBuffer, uint nInBufferSize,
    IntPtr lpOutBuffer, uint nOutBufferSize, out uint lpBytesReturned, IntPtr lpOverlapped);
[DllImport("kernel32.dll")]
public static extern bool CloseHandle(IntPtr hObject);
'@

function Get-StdCallError {
    return [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
}

function Test-Admin {
    (New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-MtIoctl {
    <# Sends an IOCTL to the control device. Returns $null on failure (with -Verbose detail). #>
    param(
        [uint32]$Code,
        [switch]$ExpectData
    )
    $GENERIC_READ = [int64]2147483648   # 0x80000000 (Windows PowerShell 5.1 parses the hex literal as Int32 -2147483648)
    $GENERIC_WRITE = [int64]1073741824  # 0x40000000
    $FILE_SHARE_RW = 3; $OPEN_EXISTING = 3

    $h = [MtTrackpad.Kernel32]::CreateFileW(
        $script:CONTROL_DEVICE,
        [uint32]($GENERIC_READ -bor $GENERIC_WRITE),
        [uint32]$FILE_SHARE_RW,
        [IntPtr]::Zero,
        [uint32]$OPEN_EXISTING,
        [uint32]0,
        [IntPtr]::Zero)

    # CreateFile returns INVALID_HANDLE_VALUE (-1) on failure, not NULL.
    if ($h.ToInt64() -eq -1 -or $h -eq [IntPtr]::Zero) {
        Write-Verbose "CreateFile($script:CONTROL_DEVICE) failed: $(Get-StdCallError)"
        return $null
    }

    $outPtr = [IntPtr]::Zero
    $outSize = [uint32]0
    $result = $null
    try {
        if ($ExpectData) {
            $outPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(4)
            $outSize = [uint32]4
        }
        $bytesReturned = [uint32]0
        $ok = [MtTrackpad.Kernel32]::DeviceIoControl(
            $h, $Code,
            [IntPtr]::Zero, 0,
            $outPtr, $outSize,
            [ref]$bytesReturned,
            [IntPtr]::Zero)

        if (-not $ok) {
            Write-Verbose ("DeviceIoControl(0x{0:X}) failed: {1}" -f $Code, (Get-StdCallError))
            return $null
        }
        if ($ExpectData) {
            $result = [System.Runtime.InteropServices.Marshal]::ReadInt32($outPtr)
        }
        else {
            # A successful no-data IOCTL has no value to return; return $true so
            # callers can tell success from the $null failure result.
            $result = $true
        }
        return $result
    }
    finally {
        if ($outPtr -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($outPtr) }
        # [void] on CloseHandle: its Boolean return would otherwise be piped out as
        # the function's result (making every caller see "success").
        [void][MtTrackpad.Kernel32]::CloseHandle($h)
    }
}

# ============================= Device discovery =============================

function Get-TrackpadUsbDevice {
    <# Returns the PnP device object for the wired trackpad's HID interface (MI_01).
       Interface instance IDs look like: USB\VID_05AC&PID_0324&MI_01\7&...&0&0001 #>
    foreach ($prefix in $script:KnownUsbInstances) {
        $dev = Get-PnpDevice -ErrorAction SilentlyContinue |
            Where-Object { $_.InstanceId -like "$prefix&MI_01\*" } |
            Select-Object -First 1
        if ($dev) { return $dev }
    }
    return $null
}

function Get-TrackpadComposite {
    <# The parent USB composite device (any of the known VIDs). #>
    foreach ($prefix in $script:KnownUsbInstances) {
        $dev = Get-PnpDevice -ErrorAction SilentlyContinue |
            Where-Object { $_.InstanceId -like "$prefix\*" -and $_.InstanceId -notlike '*&MI_*' } |
            Select-Object -First 1
        if ($dev) { return $dev }
    }
    return $null
}

function Get-TrackpadDriverDevices {
    <# All PnP entities whose bound service is our driver (covers wired + future wireless). #>
    Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object { $_.Service -eq 'AmtPtpDeviceUsbUm' }
}

function Get-TrackpadStatus {
    $usb = Get-TrackpadUsbDevice
    $composite = Get-TrackpadComposite
    $driverDevs = @(Get-TrackpadDriverDevices)

    $service = Get-CimInstance Win32_Service -Filter "Name='AmtPtpHidFilter'" -ErrorAction SilentlyContinue

    # Control device reachability (also proves the WUDF driver instance is alive)
    $ioctlOk = $false
    try {
        $ioctlOk = ($null -ne (Invoke-MtIoctl -Code $script:CTL_RELOAD_SETTINGS))
    } catch { $ioctlOk = $false }

    $battery = $null
    if ($ioctlOk) {
        $b = Invoke-MtIoctl -Code $script:CTL_GET_BATTERY -ExpectData
        if ($null -ne $b -and $b -le 100) { $battery = $b }
    }

    $boundDriver = $null
    if ($usb) { $boundDriver = $usb.Class }

    $result = [ordered]@{
        trackpadPresent        = [bool]($usb -or $composite)
        wiredUsbInstance       = if ($usb) { $usb.InstanceId } else { $null }
        wiredUsbStatus         = if ($usb) { $usb.Status } else { $null }
        wiredBoundClass        = $boundDriver
        compositeInstance      = if ($composite) { $composite.InstanceId } else { $null }
        compositeStatus        = if ($composite) { $composite.Status } else { $null }
        amtPtpDevices          = $driverDevs | ForEach-Object { [ordered]@{ PNPDeviceID = $_.PNPDeviceID; Name = $_.Name; Status = $_.Status } }
        hidFilterService       = if ($service) { [ordered]@{ State = $service.State; StartMode = $service.StartMode } } else { $null }
        controlDeviceReachable = [bool]$ioctlOk
        batteryPercent         = $battery
        timestampUtc           = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
    }
    return $result
}

# ============================= Settings =============================

function Get-MtSettings {
    $values = @{
        ButtonDisabled     = 0
        FeedbackClick      = 0x060617
        FeedbackRelease    = 0x000014
        StopPressure       = 0
        StopSize           = -1
        IgnoreButtonFinger = 1
        IgnoreNearFingers  = 1
        PalmRejection      = 1
        Rotation           = 0
    }
    # Snapshot the keys: assigning into $values while enumerating $values.Keys
    # throws "Collection was modified" as soon as any setting actually exists.
    foreach ($key in @($values.Keys)) {
        $v = Get-ItemProperty -Path $script:WUDF_PARAMS -Name $key -ErrorAction SilentlyContinue
        if ($v) {
            $read = $v.$key
            # A DWORD of 0xFFFFFFFF ("cleared", e.g. StopSize) reads back as 4294967295.
            if ($read -gt 2147483647) { $read = [int]($read - 4294967296) }
            $values[$key] = $read
        }
    }
    return $values
}

function Set-MtSettings {
    <# Mirrors the upstream control panel: writes the same settings values to BOTH the
       WUDF service Parameters key and the kernel-mode filter service Parameters key. #>
    param($Values)

    $keys = @($script:WUDF_PARAMS, $script:SVC_PARAMS)
    foreach ($k in $keys) {
        # [Microsoft.Win32.Registry]::OpenSubKey takes a hive-relative path, unlike
        # the "HKLM:\..." paths used by the PowerShell provider cmdlets.
        $hivePath = $k -replace '^HKLM:\\?', ''
        $parts = $hivePath -split '\\'
        $subkeyName = $parts[-1]
        $parentPath = ($parts[0..($parts.Count - 2)] -join '\')
        $reg = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($parentPath, $true)
        if (-not $reg) { throw "Cannot open registry parent: HKLM\$parentPath" }
        $sub = $reg.CreateSubKey($subkeyName)
        try {
            foreach ($name in @($Values.Keys)) {
                # Values read back from the registry arrive as UInt32 (e.g. StopSize
                # 0xFFFFFFFF = 4294967295) and SetValue with RegistryValueKind.DWord
                # only accepts a signed Int32, so mask into Int64 and reinterpret.
                # The mask must be decimal: PowerShell parses 0xFFFFFFFF as Int32 -1.
                $dword = ([int64]$Values[$name]) -band 4294967295
                if ($dword -gt 2147483647) { $dword -= 4294967296 }
                $sub.SetValue($name, [int]$dword, [Microsoft.Win32.RegistryValueKind]::DWord)
            }
        }
        finally { $sub.Close(); $reg.Close() }
    }
}

function Resolve-FeedbackValues {
    <# Resolves CLI switches into the FeedbackClick/FeedbackRelease/ButtonDisabled triple. #>
    param(
        [string]$FeedbackArg,
        [bool]$SilentFlag,
        [bool]$NoSilentFlag
    )
    $current = Get-MtSettings
    $click = $current.FeedbackClick
    $release = $current.FeedbackRelease
    $buttonDisabled = $current.ButtonDisabled

    if ($FeedbackArg) {
        $preset = $script:FeedbackPresets[$FeedbackArg]
        $click = $preset.Click
        $release = $preset.Release
        $buttonDisabled = if ($FeedbackArg -eq 'disabled') { 1 } else { 0 }
    }

    if ($SilentFlag) {
        $click = $click -band 0x0000FF
        $release = $release -band 0x0000FF
    }
    elseif ($NoSilentFlag) {
        # Restore default audio bits for the current preset level
        $low = $click -band 0x0000FF
        if ($low -eq 0x15) { $level = 'light' }
        elseif ($low -eq 0x17) { $level = 'medium' }
        elseif ($low -eq 0x1E) { $level = 'firm' }
        else { $level = 'medium' }
        $preset = $script:FeedbackPresets[$level]
        $click = $preset.Click
        $release = $preset.Release
    }

    return [ordered]@{
        ButtonDisabled  = $buttonDisabled
        FeedbackClick   = $click
        FeedbackRelease = $release
    }
}

function Restart-TrackpadDevices {
    <# Disable/enable all PnP instances of the trackpad so the WUDF driver re-reads settings. #>
    $instances = @()
    foreach ($prefix in $script:KnownUsbInstances) {
        $instances += @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like "$prefix\*" })
    }
    foreach ($d in $instances) {
        if ($d.Status -eq 'OK') { Disable-PnpDevice -InputObject $d -ErrorAction SilentlyContinue | Out-Null }
    }
    Start-Sleep -Seconds 2
    foreach ($d in $instances) {
        Enable-PnpDevice -InputObject $d -ErrorAction SilentlyContinue | Out-Null
    }
}

function Resolve-RotationDegrees {
    <# Normalises the CLI/GUI rotation value to the 0/90/180/270 the driver understands. #>
    param([string]$Value)
    $d = [int]$Value
    if ($d -eq -90) { $d = 270 }
    if ($d -eq 360) { $d = 0 }
    if (@(0, 90, 180, 270) -notcontains $d) {
        throw "Unsupported rotation '$Value' (use 0, 90, 180 or -90)."
    }
    return $d
}

function Set-MtRotation {
    <# Writes the Rotation DWORD to both parameter keys and reloads the driver.
       The HID report descriptor is only re-read when the device restarts, so a
       PnP restart is always part of the change. Returns a status string. #>
    param([int]$RotationValue)

    $values = Get-MtSettings
    $values.Rotation = $RotationValue
    Set-MtSettings -Values $values

    $ioctl = Invoke-MtIoctl -Code $script:CTL_RELOAD_SETTINGS
    Restart-TrackpadDevices

    if ($null -ne $ioctl) {
        return "Rotation set to $RotationValue degrees (IOCTL reload + device restart)."
    }
    return "Rotation set to $RotationValue degrees (device restart)."
}

# ============================= Actions =============================

# Finds the driver package when -DriverDir was not given: looks next to this
# script and one level up, accepting both the flat layout (driver\ with the
# INF at the top) and the upstream layout (driver\AMD64\).
function Resolve-DriverDir {
    param([string]$Dir)

    if ($Dir) { return $Dir }
    $candidates = @(
        $PSScriptRoot,
        (Join-Path $PSScriptRoot 'driver'),
        (Join-Path (Split-Path -Parent $PSScriptRoot) 'driver'),
        (Split-Path -Parent $PSScriptRoot)
    )
    foreach ($c in $candidates) {
        if (-not $c) { continue }
        foreach ($rel in @('AmtPtpDevice.inf', 'AMD64\AmtPtpDevice.inf')) {
            if (Test-Path (Join-Path $c $rel)) { return $c }
        }
    }
    return $null
}

function Invoke-Install {
    param([string]$Dir)

    if (-not (Test-Admin)) { Write-Output "WARN: not running elevated; install may fail" }
    $Dir = Resolve-DriverDir -Dir $Dir
    if (-not $Dir) { throw "driver package not found - pass -DriverDir <folder containing AmtPtpDevice.inf>" }
    $inf = Join-Path $Dir 'AMD64\AmtPtpDevice.inf'
    if (-not (Test-Path $inf)) { $inf = Join-Path $Dir 'AmtPtpDevice.inf' }
    if (-not (Test-Path $inf)) { throw "Driver INF not found at $inf" }

    # 1. Trust our self-signed code-signing certificate (so the CAT validates).
    #    Import into LocalMachine\Root (CAT signature validation walks the root store)
    #    and LocalMachine\CA (legacy pnputil path).
    $cers = @(Get-ChildItem -Path $Dir -Filter '*.cer' -Recurse -ErrorAction SilentlyContinue)
    if (-not $cers) {
        $extra = Join-Path (Split-Path -Parent $PSScriptRoot) 'certs'
        if (Test-Path $extra) { $cers = @(Get-ChildItem -Path $extra -Filter '*.cer' -Recurse) }
    }
    foreach ($cer in $cers) {
        try {
            $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($cer.FullName)
            foreach ($storeName in @('Root', 'CA', 'TrustedPublisher')) {
                try {
                    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($storeName, 'LocalMachine')
                    $store.Open('ReadWrite')
                    $store.Add($cert)
                    $store.Close()
                } catch {
                    Write-Output "WARN: could not import cert into LocalMachine/${storeName}: $($_.Exception.Message)"
                }
            }
            Write-Output "Trusted signing certificate: $($cert.Subject)"
        } catch {
            Write-Output "WARN: could not load $($cer.FullName): $($_.Exception.Message)"
        }
    }

    # 2. Import the driver package
    pnputil /add-driver "$inf" /install
    if ($?) { Write-Output "Driver package imported." } else { Write-Output "pnputil add-driver reported an error (see pnputil output above)." }

    # 3. Bind the wired device to the driver (re-scan PnP)
    $usb = Get-TrackpadUsbDevice
    if ($usb) {
        Write-Output "Re-scanning PnP for $($usb.InstanceId) ..."
        pnputil /scan-devices | Out-Null
        Start-Sleep -Seconds 3
        $after = Get-TrackpadUsbDevice
        Write-Output "Device class after install: $($after.Class) (status $($after.Status))"
    }
    else {
        Write-Output "No wired trackpad detected; driver package installed for next connect."
    }
}

function Invoke-Uninstall {
    param([switch]$RemoveDevices)

    if (-not (Test-Admin)) { Write-Output "WARN: not running elevated; uninstall may fail" }

    # Stop the kernel filter service first
    $svc = Get-CimInstance Win32_Service -Filter "Name='AmtPtpHidFilter'" -ErrorAction SilentlyContinue
    if ($svc) {
        Stop-Service AmtPtpHidFilter -Force -ErrorAction SilentlyContinue
        Write-Output "Stopped service AmtPtpHidFilter."
    }

    # Remove driver packages
    $pkgs = pnputil /enum-drivers | Select-String -Pattern 'AmtPtp' -Context 3,0
    if ($pkgs) {
        foreach ($p in $pkgs) {
            $line = $p.Line
            if ($line -match '^(.*\.inf)$') {
                Write-Output "Removing package: $($matches[1])"
                pnputil /delete-driver $matches[1] -f
            }
        }
    }

    # Optionally disable/remove the device instances
    if ($RemoveDevices) {
        foreach ($prefix in $script:KnownUsbInstances) {
            $devs = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like "$prefix\*" }
            foreach ($d in $devs) {
                Write-Output "Removing device: $($d.InstanceId)"
                Remove-PnpDevice -InputObject $d -ErrorAction SilentlyContinue
            }
        }
    }
}

function Invoke-Status {
    $s = Get-TrackpadStatus
    if ($Json) {
        $s | ConvertTo-Json -Depth 5
    }
    else {
        $s | Format-List
    }
}

function Invoke-Settings {
    $s = Get-MtSettings
    $s | Format-List
}

function Invoke-Configure {
    if (-not (Test-Admin)) { Write-Output "WARN: not running elevated; registry writes may fail" }

    $values = Get-MtSettings

    $fb = Resolve-FeedbackValues -FeedbackArg $Feedback -SilentFlag $Silent.IsPresent -NoSilentFlag $NoSilent.IsPresent
    $values.ButtonDisabled  = $fb.ButtonDisabled
    $values.FeedbackClick   = $fb.FeedbackClick
    $values.FeedbackRelease = $fb.FeedbackRelease

    if ($PSBoundParameters.ContainsKey('StopPressure')) {
        if ($StopPressure -ge 0) {
            $values.StopPressure = $StopPressure
            $values.StopSize = -1
        } else { $values.StopPressure = -1 }
    }
    if ($PSBoundParameters.ContainsKey('StopSize')) {
        if ($StopSize -ge 0) {
            $values.StopSize = $StopSize
            $values.StopPressure = -1
        } else { $values.StopSize = -1 }
    }
    if ($Palm) { $values.PalmRejection = if ($Palm -eq 'on') { 1 } else { 0 } }
    if ($IgnoreButton) { $values.IgnoreButtonFinger = if ($IgnoreButton -eq 'on') { 1 } else { 0 } }
    if ($IgnoreNear) { $values.IgnoreNearFingers = if ($IgnoreNear -eq 'on') { 1 } else { 0 } }

    Set-MtSettings -Values $values
    Write-Output "Settings written to WUDF + HidFilter Parameters keys."

    # Reload: IOCTL + device restart so the WUDF instance picks up new values
    $r = Invoke-MtIoctl -Code $script:CTL_RELOAD_SETTINGS
    if ($null -ne $r) { Write-Output "IOCTL_RELOAD_SETTINGS accepted." }
    else { Write-Output "IOCTL_RELOAD_SETTINGS not available (driver not loaded?); relying on device restart." }

    Restart-TrackpadDevices
    Write-Output "Trackpad devices restarted; new settings active."
}

function Invoke-Battery {
    $b = Invoke-MtIoctl -Code $script:CTL_GET_BATTERY -ExpectData
    if ($null -eq $b) {
        Write-Output "Battery query failed (driver not loaded, or device not connected via Bluetooth)."
        return
    }
    if ($b -gt 100) { Write-Output "Battery value out of range: $b (device may be wired)" }
    else { Write-Output "Battery: $b%" }
}

function Invoke-Reload {
    $r = Invoke-MtIoctl -Code $script:CTL_RELOAD_SETTINGS
    if ($null -ne $r) { Write-Output "IOCTL_RELOAD_SETTINGS accepted." }
    else { Write-Output "IOCTL_RELOAD_SETTINGS not available (driver not loaded?)." }
    Restart-TrackpadDevices
    Write-Output "Trackpad devices restarted."
}

function Invoke-Rotate {
    param([string]$DegreesArg)

    if (-not $DegreesArg) {
        $current = Get-MtSettings
        Write-Output "Current rotation: $($current.Rotation) degrees. Use -Degrees 0|90|180|-90."
        return
    }
    if (-not (Test-Admin)) { Write-Output "WARN: not running elevated; registry writes may fail" }

    $degrees = Resolve-RotationDegrees -Value $DegreesArg
    Write-Output (Set-MtRotation -RotationValue $degrees)
}

function Invoke-Wireless {
    <#
    Lists Bluetooth HID devices, optionally starts the pairing UI, and reports hardware IDs
    that should be added to the INF (BTH\... entries) for wireless support.
    #>
    $btDevices = Get-CimInstance Win32_BTEDevice -ErrorAction SilentlyContinue
    if ($Pair) {
        Write-Output "Starting Bluetooth device picker (complete pairing in the UI)..."
        Start-Process 'ms-settings:bluetooth'
    }

    if (-not $btDevices) {
        Write-Output "No Bluetooth devices found. Pair the trackpad first (Settings > Bluetooth > Add device)."
        return
    }

    Write-Output "Bluetooth devices:"
    $candidates = @()
    foreach ($d in $btDevices) {
        $name = $d.Name
        $connected = $d.Connected
        $isTrackpad = $name -match 'trackpad|magic'
        Write-Output ("  {0,-30} connected={1}  {2}" -f $name, $connected, ($(if ($isTrackpad) { '<<< candidate' } else { '' })))
        if ($isTrackpad) { $candidates += $d }
    }

    # Map connected BT devices to PnP hardware IDs for the INF
    Write-Output ""
    Write-Output "PnP Bluetooth HID device instances (for INF BTH\... bindings):"
    $pnpBt = Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like 'BTHLEDEVICE\*' -or $_.InstanceId -like 'BTH\*' }
    foreach ($p in $pnpBt) {
        $mark = ''
        foreach ($c in $candidates) { if ($p.FriendlyName -eq $c.Name) { $mark = '  <<< trackpad' } }
        Write-Output ("  {0}  [{1}] {2}{3}" -f $p.InstanceId, $p.Status, $p.Class, $mark)
    }
    Write-Output ""
    Write-Output "Add the trackpad's BTH\... instance IDs to the INF [Standard.NtHardwareIDDiscovered.AddInterface] section,"
    Write-Output "then re-run: .\MtTrackpad.ps1 install -DriverDir <dir>"
}

# ============================= Autostart (logon task) =============================

function Get-MtAutostartTask {
    Get-ScheduledTask -TaskName $script:AutostartTaskName -ErrorAction SilentlyContinue
}

function Invoke-Autostart {
    <#
    A real Windows service runs in session 0 and cannot own a notification-area icon,
    so the tray utility is started by a logon scheduled task instead. The task runs
    with the highest available privileges, which is what removes the UAC consent
    prompt (and its ~2 minute auto-deny timeout) at logon.
    #>
    param([switch]$Enable, [switch]$Disable)

    if ($Enable -or $Disable) {
        if (-not (Test-Admin)) { throw 'autostart changes require an elevated shell' }
    }

    $task = Get-MtAutostartTask

    if ($Disable) {
        if ($task) {
            Unregister-ScheduledTask -TaskName $script:AutostartTaskName -Confirm:$false
            Write-Output "Autostart removed (scheduled task '$script:AutostartTaskName')."
        }
        else {
            Write-Output 'Autostart was not configured.'
        }
        return
    }

    if ($Enable) {
        $scriptPath = (Resolve-Path -LiteralPath $script:SelfPath).Path
        # $env:USERDOMAIN is empty in SSH/remote sessions, so take the account from
        # the token instead of the environment.
        $userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        # Reuse the interpreter this script is running under (bare "powershell.exe"
        # would be resolved through PATH by the task scheduler).
        $hostExe = (Get-Process -Id $PID -ErrorAction SilentlyContinue).Path
        if (-not $hostExe) { $hostExe = 'powershell.exe' }
        $action = New-ScheduledTaskAction -Execute $hostExe `
            -Argument ('-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" tray' -f $scriptPath)
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
        $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $script:AutostartTaskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force -ErrorAction Stop `
            -Description 'Starts the Magic Trackpad control utility in the notification area (elevated, no UAC prompt).' | Out-Null
        if (-not (Get-MtAutostartTask)) {
            throw 'the scheduled task was not created'
        }
        Write-Output "Autostart enabled: task '$script:AutostartTaskName' runs '$scriptPath tray' at logon as $userId (highest privileges)."
        return
    }

    if ($task) {
        $info = Get-ScheduledTaskInfo -TaskName $script:AutostartTaskName -ErrorAction SilentlyContinue
        Write-Output "Autostart: ON (task '$script:AutostartTaskName', state $($task.State), last run $($info.LastRunTime))"
        Write-Output "Task action: $((@($task.Actions) | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join '; ')"
    }
    else {
        Write-Output 'Autostart: OFF (enable with: .\MtTrackpad.ps1 autostart -On)'
    }
}

# ============================= Notification area =============================

$script:TrayIcon = $null
$script:TrayRotationItems = @{}

function Show-TrayBalloon {
    param([string]$Title, [string]$Text, [int]$TimeoutMs = 2500)
    if (-not $script:TrayIcon) { return }
    $script:TrayIcon.BalloonTipTitle = $Title
    $script:TrayIcon.BalloonTipText = $Text
    $script:TrayIcon.ShowBalloonTip($TimeoutMs)
}

function Update-TrayRotationChecks {
    $current = 0
    try { $current = [int](Get-MtSettings).Rotation } catch { }
    foreach ($key in @($script:TrayRotationItems.Keys)) {
        $script:TrayRotationItems[$key].Checked = ($key -eq $current)
    }
}

function Invoke-Tray {
    <# Resident notification-area icon. Started by the autostart task, which runs
       elevated, so the registry writes and the PnP device restart work without any
       UAC prompt at logon. #>
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $menu = New-Object System.Windows.Forms.ContextMenuStrip

    $header = $menu.Items.Add('Magic Trackpad')
    $header.Enabled = $false

    $rotationMenu = New-Object System.Windows.Forms.ToolStripMenuItem('Rotation')
    foreach ($option in @(
            @{ Degrees = 0;   Label = '0 degrees (default)' },
            @{ Degrees = 90;  Label = '90 degrees' },
            @{ Degrees = 180; Label = '180 degrees' },
            @{ Degrees = 270; Label = '-90 degrees' })) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem($option.Label)
        $item.Tag = [int]$option.Degrees
        $item.add_Click({
            param($sender, $eventArgs)
            $degrees = [int]$sender.Tag
            try {
                $null = Set-MtRotation -RotationValue $degrees
                Show-TrayBalloon -Title 'Magic Trackpad' -Text "Rotation set to $degrees degrees."
            }
            catch {
                Show-TrayBalloon -Title 'Magic Trackpad' -Text "Rotation failed: $($_.Exception.Message)" -TimeoutMs 4000
            }
            Update-TrayRotationChecks
        })
        $script:TrayRotationItems[[int]$option.Degrees] = $item
        [void]$rotationMenu.DropDownItems.Add($item)
    }
    [void]$menu.Items.Add($rotationMenu)

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $reloadItem = New-Object System.Windows.Forms.ToolStripMenuItem('Reload driver')
    $reloadItem.add_Click({
        param($sender, $eventArgs)
        try {
            Invoke-Reload | Out-Null
            Show-TrayBalloon -Title 'Magic Trackpad' -Text 'Driver reloaded.'
        }
        catch {
            Show-TrayBalloon -Title 'Magic Trackpad' -Text "Reload failed: $($_.Exception.Message)" -TimeoutMs 4000
        }
    })
    [void]$menu.Items.Add($reloadItem)

    $statusItem = New-Object System.Windows.Forms.ToolStripMenuItem('Status')
    $statusItem.add_Click({
        param($sender, $eventArgs)
        try {
            $s = Get-TrackpadStatus
            Show-TrayBalloon -Title 'Magic Trackpad' -TimeoutMs 4000 `
                -Text "present=$($s.trackpadPresent); control-device=$($s.controlDeviceReachable); battery=$($s.batteryPercent)"
        }
        catch {
            Show-TrayBalloon -Title 'Magic Trackpad' -Text "Status failed: $($_.Exception.Message)" -TimeoutMs 4000
        }
    })
    [void]$menu.Items.Add($statusItem)

    $autostartItem = New-Object System.Windows.Forms.ToolStripMenuItem('Start at logon')
    $autostartItem.Checked = [bool](Get-MtAutostartTask)
    $autostartItem.add_Click({
        param($sender, $eventArgs)
        try {
            if (Get-MtAutostartTask) {
                Invoke-Autostart -Disable | Out-Null
                Show-TrayBalloon -Title 'Magic Trackpad' -Text 'Autostart disabled.'
            }
            else {
                Invoke-Autostart -Enable | Out-Null
                Show-TrayBalloon -Title 'Magic Trackpad' -Text 'Autostart enabled (runs elevated at logon).'
            }
        }
        catch {
            Show-TrayBalloon -Title 'Magic Trackpad' -Text "Autostart change failed: $($_.Exception.Message)" -TimeoutMs 4000
        }
        $sender.Checked = [bool](Get-MtAutostartTask)
    })
    [void]$menu.Items.Add($autostartItem)

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem('Exit')
    $exitItem.add_Click({
        param($sender, $eventArgs)
        if ($script:TrayIcon) { $script:TrayIcon.Visible = $false }
        [System.Windows.Forms.Application]::Exit()
    })
    [void]$menu.Items.Add($exitItem)

    $script:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
    $script:TrayIcon.Icon = [System.Drawing.SystemIcons]::Application
    $script:TrayIcon.Text = 'Magic Trackpad control'
    $script:TrayIcon.ContextMenuStrip = $menu
    $script:TrayIcon.Visible = $true

    Update-TrayRotationChecks
    Show-TrayBalloon -Title 'Magic Trackpad' -Text 'Control utility running. Rotation is in the tray menu.'

    [System.Windows.Forms.Application]::Run()
    $script:TrayIcon.Dispose()
}

# ============================= Dispatch =============================
switch ($Action) {
    'install'   { Invoke-Install -Dir $DriverDir }
    'uninstall' { Invoke-Uninstall -RemoveDevices:$Force }
    'status'    { Invoke-Status }
    'settings'  { Invoke-Settings }
    'configure' { Invoke-Configure }
    'battery'   { Invoke-Battery }
    'reload'    { Invoke-Reload }
    'wireless'  { Invoke-Wireless }
    'rotate'    { Invoke-Rotate -DegreesArg $Degrees }
    'tray'      { Invoke-Tray }
    'autostart' { Invoke-Autostart -Enable:$On -Disable:$Off }
}
