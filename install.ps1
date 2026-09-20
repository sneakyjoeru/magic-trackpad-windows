<#
    Magic Trackpad for Windows - one-shot installer
    ===============================================

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
    [switch]$Autostart,
    [switch]$StartMinimized,
    [switch]$SkipLaunch,
    [switch]$NoShortcuts,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$driverDir = Join-Path $root 'driver'
$certDir   = Join-Path $root 'certs'
$appName   = 'AmtPtpControlPanel.exe'
$appSrc    = Join-Path $root $appName
$utilDir   = Join-Path $root 'utility'
$runKey    = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runValue  = 'Magic Trackpad'

function Write-Step($text) { Write-Host "==> $text" -ForegroundColor Cyan }
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

function Install-Driver {
    $inf = Get-DriverInf
    if (-not $inf) { throw "driver INF not found - expected driver\AmtPtpDevice.inf inside the archive" }

    $existing = @(Get-ExistingDriverPackages)
    if ($existing.Count -gt 0) {
        Write-Step "driver package already present ($($existing -join ', ')) - re-binding instead of importing a copy"
    } else {
        Write-Step "importing driver package ($inf)"
        $out = & pnputil.exe /add-driver "$inf" /install 2>&1
        $out | ForEach-Object { Write-Host "    $_" }
        if ($LASTEXITCODE -ne 0 -and ($out -notmatch 'already')) {
            throw "pnputil /add-driver failed (exit $LASTEXITCODE)"
        }
        Write-Ok 'driver package imported'
    }

    Write-Step 're-scanning devices'
    & pnputil.exe /scan-devices | Out-Null
    Start-Sleep -Seconds 4
}

function Show-DeviceState {
    Write-Step 'trackpad device state'
    # matches the wired USB ids (VID_05AC / VID_27A7) and the Bluetooth
    # HID enumeration, which writes the vendor id as "VID&0001004C"
    $devices = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match 'VID[&_]0*5AC|VID[&_]0*27A7|VID&0001004[Cc]|VID&000127[Aa]7' }
    if (-not $devices) {
        Write-Warn2 'no Magic Trackpad hardware found (connect it by USB-C or pair it over Bluetooth, then re-run with -DriverOnly)'
        return $false
    }
    $ok = $false
    foreach ($d in $devices) {
        Write-Host ("    {0,-8} {1,-10} {2}" -f $d.Status, $d.Class, $d.InstanceId)
        if ($d.Status -eq 'OK') { $ok = $true }
    }
    if ($ok) { Write-Ok 'device is started' } else { Write-Warn2 'device present but not started - unplug/replug the cable or reboot' }
    return $ok
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

function Uninstall-All {
    Write-Step 'stopping the control panel'
    Get-Process -Name 'AmtPtpControlPanel' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Remove-Autostart

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

    Write-Step 'removing certificates'
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

    if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force; Write-Ok "removed $InstallDir" }
}

# ------------------------------- main -------------------------------

Write-Host ''
Write-Host 'Magic Trackpad for Windows - installer' -ForegroundColor White
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
    Write-Step 'trusting the driver certificate(s)'
    Import-DriverCerts

    Install-Driver
    $deviceOk = Show-DeviceState

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
} catch {
    Write-Host ''
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
