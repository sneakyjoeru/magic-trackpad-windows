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

.EXAMPLE
    .\MtTrackpad.ps1 install -DriverDir C:\MtTrackpad\Driver
.EXAMPLE
    .\MtTrackpad.ps1 configure -Feedback medium -Silent -StopPressure 50 -Palm on
.EXAMPLE
    .\MtTrackpad.ps1 status -Json
.EXAMPLE
    .\MtTrackpad.ps1 battery
.EXAMPLE
    .\MtTrackpad.ps1 wireless -Pair
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('install', 'uninstall', 'status', 'settings', 'configure', 'battery', 'reload', 'wireless')]
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
    [switch]$Pair
)

$ErrorActionPreference = 'Stop'

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
        [bool]$ExpectData = $false
    )
    $GENERIC_READ = 0x80000000; $GENERIC_WRITE = 0x40000000
    $FILE_SHARE_RW = 3; $OPEN_EXISTING = 3

    $h = [MtTrackpad.Kernel32]::CreateFileW(
        $script:CONTROL_DEVICE,
        [uint32]($GENERIC_READ -bor $GENERIC_WRITE),
        [uint32]$FILE_SHARE_RW,
        [IntPtr]::Zero,
        [uint32]$OPEN_EXISTING,
        [uint32]0,
        [IntPtr]::Zero)

    if ([int]$h -eq 0) {
        Write-Verbose "CreateFile($script:CONTROL_DEVICE) failed: $(Get-StdCallError)"
        return $null
    }

    $outPtr = [IntPtr]::Zero
    $result = $null
    try {
        if ($ExpectData) {
            $outPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(4)
        }
        $bytesReturned = [uint32]0
        $ok = [MtTrackpad.Kernel32]::DeviceIoControl(
            $h, $Code,
            [IntPtr]::Zero, 0,
            $outPtr, [uint32](if ($ExpectData) { 4 } else { 0 }),
            [ref]$bytesReturned,
            [IntPtr]::Zero)

        if (-not $ok) {
            Write-Verbose "DeviceIoControl(0x{0:X}) failed: $(Get-StdCallError)" -f $Code
            return $null
        }
        if ($ExpectData) {
            $result = [System.Runtime.InteropServices.Marshal]::ReadInt32($outPtr)
        }
        return $result
    }
    finally {
        if ($outPtr -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($outPtr) }
        [MtTrackpad.Kernel32]::CloseHandle($h)
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
        $null = Invoke-MtIoctl -Code $script:CTL_RELOAD_SETTINGS -Verbose
        $ioctlOk = $true
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
    }
    foreach ($key in $values.Keys) {
        $v = Get-ItemProperty -Path $script:WUDF_PARAMS -Name $key -ErrorAction SilentlyContinue
        if ($v) { $values[$key] = $v.$key }
    }
    return $values
}

function Set-MtSettings {
    <# Mirrors the upstream control panel: writes the same 8 values to BOTH the WUDF
       service Parameters key and the kernel-mode filter service Parameters key. #>
    param($Values)

    $keys = @($script:WUDF_PARAMS, $script:SVC_PARAMS)
    foreach ($k in $keys) {
        $hivePath = $k -replace '^HKLM:', ''
        $parts = $hivePath -split '\\'
        $subkeyName = $parts[-1]
        $parentPath = ('HKLM:' + ($parts[0..($parts.Count - 2)] -join '\'))
        $reg = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($parentPath, $true)
        if (-not $reg) { throw "Cannot open registry parent: $parentPath" }
        $sub = $reg.CreateSubKey($subkeyName)
        try {
            foreach ($name in $Values.Keys) {
                $sub.SetValue($name, [int]$Values[$name], [Microsoft.Win32.RegistryValueKind]::DWord)
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

# ============================= Actions =============================

function Invoke-Install {
    param([string]$Dir)

    if (-not (Test-Admin)) { Write-Output "WARN: not running elevated; install may fail" }
    if (-not $Dir) { throw "-DriverDir is required for install (must contain AMD64\AmtPtpDevice.inf)" }
    $amd64 = Join-Path $Dir 'AMD64'
    $inf = Join-Path $amd64 'AmtPtpDevice.inf'
    if (-not (Test-Path $inf)) { throw "Driver INF not found at $inf" }

    # 1. Trust our self-signed code-signing certificate (so the CAT validates).
    #    Import into LocalMachine\Root (CAT signature validation walks the root store)
    #    and LocalMachine\CA (legacy pnputil path).
    $cer = Get-ChildItem -Path $Dir -Filter '*.cer' -Recurse | Select-Object -First 1
    if ($cer) {
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($cer.FullName)
        foreach ($storeName in @('Root', 'CA')) {
            try {
                $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($storeName, 'LocalMachine')
                $store.Open('ReadWrite')
                $store.Add($cert)
                $store.Close()
            } catch {
                Write-Output "WARN: could not import cert into LocalMachine\$storeName: $($_.Exception.Message)"
            }
        }
        Write-Output "Trusted signing certificate: $($cert.Subject)"
    }

    # 2. Import the driver package
    pnputil /add-driver "$amd64\AmtPtpDevice.inf" /install
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
}
