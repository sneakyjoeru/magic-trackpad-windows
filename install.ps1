<#
    Apple Magic Trackpad Setup Utility + Drivers v1.0 - installer
    ============================================================

    (Driver + panel from vitoplantamura/MagicTrackpad2ForWindows and
     imbushuo/mac-precision-touchpad - see README.txt for full attribution.)

    Installs EVERYTHING that is needed on a fresh Windows host:

      1. trusts the self-signed driver certificate(s) shipped in .\certs
         (LocalMachine\Root, \CA and \TrustedPublisher),
      2. imports the driver package shipped in .\driver
         (pnputil /add-driver ... /install) and re-scans PnP,
      3. verifies that the trackpad device is present and started,
      4. copies the tray control panel to a per-user folder,
      5. optionally registers per-user autostart,
      6. launches the control panel (UAC prompt).

    Run it from the extracted archive, elevated:

        powershell -ExecutionPolicy Bypass -File .\install.ps1

    Options:
        -InstallDir <path>   where the control panel is copied
                             (default: %LOCALAPPDATA%\MagicTrackpad)
        -DriverOnly          only trust the certs + install the driver
        -SelfSigned          install a self-signed package from
                             driver-self-signed\ (if present) and trust the
                             certificates in certs\. Only needed for VID 27A7
                             clones, and only with "bcdedit /set testsigning on".
                             The default (driver\) is Microsoft-signed and needs
                             neither.
        -NoRepair            do not run the automatic repair (old Apple/self-signed
                             drivers removed, devices restarted) when the driver
                             does not come up. The repair runs by default.
        -Clean               first remove every known Apple/trackpad driver and
                             leftover device instance (clean slate), then install
        -Autostart           add the per-user Run entry (one UAC per logon)
        -StartMinimized      with -Autostart: start straight into the tray
        -SkipLaunch          do not start the control panel at the end
        -NoShortcuts         do not create the Start Menu shortcut
        -Uninstall           remove app + autostart + driver + certificates

    Exit code 0 = success, 1 = a step failed (details on the console).
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'MagicTrackpad'),
    [switch]$DriverOnly,
    [switch]$SelfSigned,
    [switch]$Clean,
    [switch]$NoRepair,
    [switch]$Autostart,
    [switch]$StartMinimized,
    [switch]$SkipLaunch,
    [switch]$NoShortcuts,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$driverDir = Join-Path $root 'driver'          # Microsoft-signed (default)
if ($SelfSigned) {
    $selfDir = Join-Path $root 'driver-self-signed'
    if (Test-Path $selfDir) { $driverDir = $selfDir }
    else { throw "driver-self-signed\ is not in this package - build it from source (driver\build\make_win10.bat) if you really need the self-signed driver" }
}
$certDir   = Join-Path $root 'certs'
$appName   = 'AmtPtpControlPanel.exe'
$appSrc    = Join-Path $root $appName
$utilDir   = Join-Path $root 'utility'
$runKey    = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runValue  = 'Magic Trackpad'

function Write-Step($text) { Write-Host "==> $text" -ForegroundColor Cyan }
function Write-Info($text) { Write-Host "    $text" }
function Write-Ok($text)   { Write-Host "    OK   $text" -ForegroundColor Green }
function Write-Warn2($text){ Write-Host "    WARN $text" -ForegroundColor Yellow }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-ElevatedSelf {
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [switch]) {
            if ($kv.Value.IsPresent) { $argList += "-$($kv.Key)" }
        } else {
            $argList += @("-$($kv.Key)", "`"$($kv.Value)`"")
        }
    }
    Write-Step 'Not elevated - restarting with a UAC prompt'
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
}

function Get-DriverInf {
    $candidates = @(
        (Join-Path $driverDir 'AmtPtpDevice.inf'),
        (Join-Path $driverDir 'AMD64\AmtPtpDevice.inf')
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    return $null
}

function Import-DriverCerts {
    if (-not (Test-Path $certDir)) { Write-Warn2 "no certs folder at $certDir"; return }
    $certs = Get-ChildItem -Path $certDir -Filter '*.cer' -File
    if (-not $certs) { Write-Warn2 "no .cer files in $certDir"; return }
    foreach ($file in $certs) {
        try {
            $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($file.FullName)
            foreach ($storeName in @('Root','CA','TrustedPublisher')) {
                try {
                    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($storeName,'LocalMachine')
                    $store.Open('ReadWrite')
                    $store.Add($cert)
                    $store.Close()
                } catch {
                    Write-Warn2 "store LocalMachine\$storeName : $($_.Exception.Message)"
                }
            }
            Write-Ok "trusted $($cert.Subject)"
        } catch {
            Write-Warn2 "could not load $($file.Name): $($_.Exception.Message)"
        }
    }
}

function Get-ExistingDriverPackages {
    $published = @()
    $current = $null
    foreach ($line in (& pnputil.exe /enum-drivers)) {
        if ($line -match '^Published Name\s*:\s*(oem\d+\.inf)') { $current = $Matches[1] }
        elseif ($line -match '^Original Name\s*:\s*(.+)$' -and $current) {
            if ($Matches[1].Trim() -ieq 'amtptpdevice.inf') { $published += $current }
            $current = $null
        }
    }
    return $published
}

function Get-InstalledDriverKind {
    # Windows keeps the imported package under DriverStore\FileRepository\amtptpdevice.inf_*
    # Reading the catalogue's signer tells us whether the installed package is
    # ours (self-signed) or the Microsoft-signed one.
    $kinds = @()
    $repo = Join-Path $env:windir 'System32\DriverStore\FileRepository'
    foreach ($dir in (Get-ChildItem $repo -Directory -Filter 'amtptpdevice.inf_*' -ErrorAction SilentlyContinue)) {
        foreach ($cat in (Get-ChildItem $dir.FullName -Filter '*.cat' -ErrorAction SilentlyContinue)) {
            $subject = ''
            try { $subject = (Get-AuthenticodeSignature $cat.FullName).SignerCertificate.Subject } catch { }
            if ($subject -match 'Microsoft') { $kinds += 'microsoft' }
            elseif ($subject) { $kinds += 'self-signed' }
            else { $kinds += 'unknown' }
        }
    }
    return @($kinds | Select-Object -Unique)
}

function Install-Driver {
    $inf = Get-DriverInf
    if (-not $inf) { throw "driver INF not found - expected driver\AmtPtpDevice.inf inside the archive" }

    $existing = @(Get-ExistingDriverPackages)
    $installedKinds = @(Get-InstalledDriverKind)
    # no ternary operator: Windows PowerShell 5.1 does not have one
    $want = 'microsoft'
    if ($SelfSigned) { $want = 'self-signed' }
    $have = $installedKinds -contains $want

    if ($want -eq 'microsoft') {
        if ($have) {
            Write-Step 'Microsoft-signed package already installed - re-binding'
        } else {
            Write-Step 'importing the Microsoft-signed driver package'
            if ($existing.Count -gt 0) {
                Write-Warn2 "an older self-signed package is also present ($($existing -join ', ')) - it can be removed later with Uninstall-All-Apple-Drivers.cmd"
            }
        }
    } elseif ($have) {
        Write-Step "self-signed package already installed ($($existing -join ', ')) - re-binding instead of importing a copy"
    }

    if (-not $have) {
        Write-Step "importing driver package ($inf)"
        $out = & pnputil.exe /add-driver "$inf" /install 2>&1
        $out | ForEach-Object { Write-Host "    $_" }
        if ($LASTEXITCODE -ne 0 -and ($out -notmatch 'already')) {
            throw "pnputil /add-driver failed (exit $LASTEXITCODE)"
        }
        Write-Ok 'driver package imported'
    } else {
        Write-Ok ("installed package kind: " + ($installedKinds -join ', '))
    }

    Write-Step 're-scanning devices'
    & pnputil.exe /scan-devices | Out-Null
    Start-Sleep -Seconds 4
}

function Get-TestSigningState {
    try {
        $out = (& bcdedit.exe /enum '{current}' 2>$null) -join "`n"
        if ($out -match 'testsigning\s+(\w+)') { return $Matches[1] }
    } catch { }
    return 'unknown'
}

function Get-SecureBootState {
    try { return (Confirm-SecureBootUEFI) } catch { return 'unknown' }
}

function Get-ConnectedTrackpadDevices {
    # Instance IDs of every trackpad-ish device. Three sources, because no
    # single one works everywhere: pnputil /enum-devices exists only on newer
    # builds, Get-PnpDevice reports a different set when running elevated from
    # a scheduled task, and ghosts only show up without -PresentOnly.
    $ids = @()
    try {
        foreach ($line in (& pnputil.exe /enum-devices /connected 2>$null)) {
            if ($line -match 'Instance ID\s*:\s*(.+)$') {
                $id = $Matches[1].Trim()
                if ($id -match '05AC|27A7|0001004C' -and $id -match '0265|0324|030E|2501|9601') { $ids += $id }
            }
        }
    } catch { }
    if ($ids.Count -gt 0) { return $ids }

    $ids = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match '05AC|27A7|0001004C' -and $_.InstanceId -match '0265|0324|030E|2501|9601' } |
        ForEach-Object { $_.InstanceId })
    if ($ids.Count -gt 0) { return $ids }

    $ids = @(Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match '05AC|27A7|0001004C' -and $_.InstanceId -match '0265|0324|030E|2501|9601' } |
        ForEach-Object { $_.InstanceId })
    return $ids
}

function Restart-TrackpadDevices {
    # A device bound to a driver that failed to start stays in "Error" until the
    # instance is restarted - switching packages is not enough on its own.
    $present = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match '05AC|27A7|0001004C' -and $_.InstanceId -match '0265|0324|030E|2501|9601' })
    if ($present.Count -eq 0) { return $false }
    Write-Step 'restarting the trackpad device instances so Windows re-binds them'
    $done = 0
    foreach ($d in $present) {
        $out = & pnputil.exe /restart-device "$($d.InstanceId)" 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Ok "restarted $($d.InstanceId)"; $done++ }
        else { Write-Info "could not restart $($d.InstanceId)" }
    }
    if ($done -gt 0) { Start-Sleep -Seconds 5 }
    return ($done -gt 0)
}

function Test-ControlDevice {
    # Exactly what the control panel does: CreateFile on the driver's control
    # device. A missing device object returns error 2, which the panel shows as
    # "Failed to open device. Error: 2".
    $src = @'
using System;
using System.Runtime.InteropServices;
public class MtControlDevice {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFile(
        string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
}
'@
    try { if (-not ('MtControlDevice' -as [type])) { Add-Type -TypeDefinition $src | Out-Null } }
    catch { return @{ Ok = $false; Error = -1 } }

    # decimal literals on purpose: Windows PowerShell parses 0x80000000 as a
    # negative Int32 and the [uint32] cast then throws
    $access = [uint32]2147483648 -bor [uint32]1073741824   # GENERIC_READ|GENERIC_WRITE
    $h = [MtControlDevice]::CreateFile('\\.\AmtPtpControlDeviceUm',
        $access, [uint32]3, [IntPtr]::Zero, [uint32]3, [uint32]0, [IntPtr]::Zero)
    if ($h -and -not $h.IsInvalid) { $h.Dispose(); return @{ Ok = $true; Error = 0 } }
    $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    return @{ Ok = $false; Error = $err }
}

function Show-ControlDeviceState {
    $probe = Test-ControlDevice
    if ($probe.Ok) {
        Write-Ok 'driver control device \\.\AmtPtpControlDeviceUm is available'
        return $true
    }
    Write-Warn2 "driver control device \\.\AmtPtpControlDeviceUm is NOT available (Win32 error $($probe.Error))"
    switch ($probe.Error) {
        2       { Write-Host '    Error 2 = the device object does not exist: the trackpad is not bound to this driver.' }
        5       { Write-Host '    Error 5 = access denied: this installer is not running elevated.' }
        default { Write-Host "    Win32 error $($probe.Error) while opening the driver control device." }
    }
    Write-Host '    The control panel would report "Failed to open device. Error: 2".'
    $ts = Get-TestSigningState
    $sb = Get-SecureBootState
    Write-Host "    test signing: $ts    secure boot: $sb"
    if ($SelfSigned -and $ts -ne 'Yes') {
        Write-Host ''
        Write-Host '    *** The self-signed package cannot load its KERNEL driver without test signing.' -ForegroundColor Yellow
        Write-Host '        Enable it, then reboot:  bcdedit /set testsigning on   (Secure Boot off)' -ForegroundColor Yellow
        Write-Host '        Better: use the Microsoft-signed package (the default) - it needs' -ForegroundColor Yellow
        Write-Host '        neither test signing nor certificates, but does not cover VID 27A7.' -ForegroundColor Yellow
        Write-Host ''
    }
    Write-Host '    Fix, in order:'
    Write-Host '      1. unplug the USB-C cable and plug it back in (or remove + re-pair Bluetooth), then run this installer again'
    Write-Host '      2. reboot once - a WUDF host or a stale device instance can be stuck'
    Write-Host '      3. with the trackpad attached, run Install.cmd again: it repairs old Apple /'
    Write-Host '         self-signed drivers and restarts the device by itself (or use -Clean for a'
    Write-Host '         forced clean slate)'
    Write-Host '      4. if it still fails, the device list above is what we need: the hardware IDs'
    Write-Host '         may not be covered by the driver INF'
    return $false
}

function Invoke-DriverRepair {
    # Automatic repair, part of every install: wipe every Apple / Magic
    # Trackpad driver package and leftover device instance,
    # device instance, install the shipped (Microsoft-signed) package and
    # restart the trackpad devices so Windows really re-binds them.
    Write-Host ''
    Write-Host '==> the driver is not working yet - running the automatic repair' -ForegroundColor Yellow
    $cleanup = Join-Path $root 'Uninstall-All-Apple-Drivers.ps1'
    if (Test-Path $cleanup) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cleanup
        Write-Host ''
    } else {
        Write-Warn2 "cleanup helper not found at $cleanup - removing packages directly"
        foreach ($pkg in @(Get-ExistingDriverPackages)) {
            & pnputil.exe /delete-driver $pkg /uninstall /force 2>&1 | ForEach-Object { Write-Info $_ }
        }
    }

    Install-Driver
    Show-DeviceState | Out-Null
    Restart-TrackpadDevices | Out-Null
    Write-Host ''
    Write-Host '==> re-checking after the repair' -ForegroundColor Cyan
    return (Test-ControlDevice).Ok
}

function Show-DeviceState {
    Write-Step 'trackpad device state'
    # pnputil is used instead of Get-PnpDevice: the CIM-based cmdlet reports a
    # different (sometimes empty) "present" set when run elevated from a
    # service/scheduled-task context, while pnputil always reflects the real
    # device tree.
    $devices = @(Get-ConnectedTrackpadDevices)
    if ($devices.Count -eq 0) {
        Write-Warn2 'no connected Magic Trackpad hardware found (connect it by USB-C or pair it over Bluetooth, then re-run with -DriverOnly)'
        return $false
    }
    foreach ($d in $devices) { Write-Host "    $d" }
    $problems = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match '05AC|27A7|0001004C' -and $_.InstanceId -match '0265|0324|030E|2501|9601' -and $_.Status -ne 'OK' })
    if ($problems.Count -gt 0) {
        Write-Warn2 'device present but not started - unplug/replug the cable or reboot'
        return $false
    }
    Write-Ok 'device is present'
    return $true
}

function Install-App {
    Write-Step "installing the control panel to $InstallDir"
    if (-not (Test-Path $appSrc)) { throw "app not found at $appSrc" }
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Copy-Item $appSrc (Join-Path $InstallDir $appName) -Force
    Write-Ok (Join-Path $InstallDir $appName)
    if (Test-Path $utilDir) {
        Copy-Item $utilDir (Join-Path $InstallDir 'utility') -Recurse -Force
        Write-Ok (Join-Path $InstallDir 'utility')
    }
    foreach ($doc in @('README.txt','INSTALL.txt')) {
        $p = Join-Path $root $doc
        if (Test-Path $p) { Copy-Item $p $InstallDir -Force }
    }
    if (-not $NoShortcuts) {
        $exe = Join-Path $InstallDir $appName
        $link = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Magic Trackpad.lnk'
        New-Shortcut -LinkPath $link -TargetPath $exe `
            -Description 'Magic Trackpad control panel (runs with administrator rights)' `
            -IconPath "$exe,0"
        Write-Ok "Start Menu shortcut: $link"
    }
}

function New-Shortcut {
    param(
        [string]$LinkPath,
        [string]$TargetPath,
        [string]$Description = '',
        [string]$IconPath = ''
    )
    $parent = Split-Path -Parent $LinkPath
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($LinkPath)
    $lnk.TargetPath = $TargetPath
    $lnk.WorkingDirectory = (Split-Path -Parent $TargetPath)
    if ($Description) { $lnk.Description = $Description }
    if ($IconPath)    { $lnk.IconLocation = $IconPath }
    $lnk.Save()
    # set the "run as administrator" flag (byte 0x15, bit 0x20) so launching
    # the panel from the Start Menu goes straight to the elevated copy
    try {
        $bytes = [IO.File]::ReadAllBytes($LinkPath)
        if ($bytes.Length -gt 0x15) {
            $bytes[0x15] = $bytes[0x15] -bor 0x20
            [IO.File]::WriteAllBytes($LinkPath, $bytes)
        }
    } catch { }
}

function Set-Autostart {
    $exe = Join-Path $InstallDir $appName
    $cmd = "`"$exe`""
    if ($StartMinimized) { $cmd += ' -minimized' }
    New-Item -Path $runKey -Force | Out-Null
    New-ItemProperty -Path $runKey -Name $runValue -Value $cmd -PropertyType String -Force | Out-Null
    Write-Ok "autostart: $runValue = $cmd"
}

function Remove-Autostart {
    if (Get-ItemProperty -Path $runKey -Name $runValue -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $runKey -Name $runValue -Force
        Write-Ok 'autostart entry removed'
    }
}

function Remove-Shortcuts {
    foreach ($link in @(
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Magic Trackpad.lnk'),
        (Join-Path $env:PUBLIC 'Desktop\Magic Trackpad.lnk'),
        (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Magic Trackpad.lnk')
    )) {
        if ($link -and (Test-Path $link)) { Remove-Item $link -Force -ErrorAction SilentlyContinue; Write-Ok "removed $link" }
    }
}

function Stop-ControlPanel {
    $procs = @(Get-Process -Name 'AmtPtpControlPanel' -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { Write-Info 'control panel is not running'; return }
    Write-Step "closing the control panel ($($procs.Count) process(es))"
    foreach ($p in $procs) {
        try { $p.CloseMainWindow() | Out-Null } catch { }
    }
    Start-Sleep -Seconds 1
    $left = @(Get-Process -Name 'AmtPtpControlPanel' -ErrorAction SilentlyContinue)
    foreach ($p in $left) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { } }
    Start-Sleep -Milliseconds 500
    $left2 = @(Get-Process -Name 'AmtPtpControlPanel' -ErrorAction SilentlyContinue)
    if ($left2.Count -eq 0) { Write-Ok 'control panel closed' } else { Write-Warn2 "still running: $(($left2 | ForEach-Object { $_.Id }) -join ', ')" }
}

function Uninstall-All {
    Stop-ControlPanel
    Remove-Autostart
    Remove-Shortcuts

    Write-Step 'removing driver packages'
    $ids = (& pnputil.exe /enum-drivers) | Select-String -Pattern 'oem\d+\.inf' |
        ForEach-Object { $_.Matches[0].Value }
    foreach ($id in $ids) {
        $block = (& pnputil.exe /enum-drivers) -join "`n"
        $idx = $block.IndexOf($id)
        if ($idx -ge 0) {
            $chunk = $block.Substring($idx, [Math]::Min(600, $block.Length - $idx))
            if ($chunk -match 'amtptpdevice\.inf') {
                & pnputil.exe /delete-driver $id /uninstall /force | ForEach-Object { Write-Host "    $_" }
                Write-Ok "removed $id"
            }
        }
    }

    Write-Step 'removing this project''s certificates (if any were trusted)'
    foreach ($file in (Get-ChildItem -Path $certDir -Filter '*.cer' -File -ErrorAction SilentlyContinue)) {
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($file.FullName)
        foreach ($storeName in @('Root','CA','TrustedPublisher')) {
            try {
                $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($storeName,'LocalMachine')
                $store.Open('ReadWrite')
                $store.Remove($cert)
                $store.Close()
            } catch { }
        }
        Write-Ok "untrusted $($cert.Subject)"
    }

    Write-Step 'removing the installed application'
    if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force; Write-Ok "removed $InstallDir" }
    else { Write-Info "$InstallDir was not present" }
}

# ------------------------------- main -------------------------------

Write-Host ''
Write-Host 'Apple Magic Trackpad Setup Utility + Drivers v1.0' -ForegroundColor White
Write-Host "  archive : $root"
Write-Host ''

if (-not (Test-Admin)) {
    Invoke-ElevatedSelf
    return
}

if ($Uninstall) {
    Uninstall-All
    Write-Host ''
    Write-Host 'Uninstall finished.' -ForegroundColor Green
    return
}

try {
    if ($Clean) {
        $cleanup = Join-Path $root 'Uninstall-All-Apple-Drivers.ps1'
        if (Test-Path $cleanup) {
            Write-Step 'clean slate: removing every known Apple / trackpad driver first'
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cleanup
            Write-Host ''
        } else {
            Write-Warn2 "cleanup script not found at $cleanup"
        }
    }

    if ($SelfSigned) {
        Write-Step 'self-signed package selected - trusting its certificate(s)'
        Import-DriverCerts
    } else {
        Write-Step 'Microsoft-signed package (default) - no certificate to trust'
    }

    Install-Driver
    $deviceOk = Show-DeviceState
    $ctrlOk = Show-ControlDeviceState
    if (-not $ctrlOk) {
        # the usual leftover after switching driver packages: the device is stuck
        # in an error state - restart it and look again
        if (Restart-TrackpadDevices) {
            Write-Step 're-checking the driver control device'
            $ctrlOk = Show-ControlDeviceState
        }
    }
    if (-not $ctrlOk -and -not $NoRepair) {
        # a trackpad is attached but the driver is not up (typical after moving
        # the unit from a machine that had Apple's or an older self-signed
        # driver) - repair instead of just complaining
        $attached = @(Get-ConnectedTrackpadDevices).Count -gt 0
        $foreign = @(Get-InstalledDriverKind | Where-Object { $_ -ne 'microsoft' }).Count -gt 0
        if ($attached -or $foreign) {
            if (Invoke-DriverRepair) {
                $ctrlOk = Show-ControlDeviceState
            }
        } else {
            Write-Info 'no trackpad attached - nothing to bind, error 2 is expected until you connect it'
        }
    }

    if (-not $DriverOnly) {
        Install-App
        if ($Autostart) { Set-Autostart }
        if (-not $SkipLaunch) {
            $exe = Join-Path $InstallDir $appName
            Write-Step 'starting the control panel (accept the UAC prompt)'
            Start-Process -FilePath $exe
        }
        Write-Host ''
        Write-Host 'Install finished.' -ForegroundColor Green
        Write-Host '  Right-click the tray icon for settings; the Battery group shows the charge.'
        Write-Host "  App folder: $InstallDir"
        if (-not $Autostart) {
            Write-Host '  Start with Windows: tray menu -> "Start with Windows", or re-run with -Autostart.'
        }
    } else {
        Write-Host ''
        Write-Host 'Driver install finished.' -ForegroundColor Green
    }
    if (-not $deviceOk) {
        Write-Host '  NOTE: the trackpad was not detected as started - connect/replug it and re-run with -DriverOnly.' -ForegroundColor Yellow
    }
    if (-not $ctrlOk) {
        Write-Host '  NOTE: the driver control device is missing - see the fix list above; the panel needs it.' -ForegroundColor Yellow
    }
} catch {
    Write-Host ''
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
