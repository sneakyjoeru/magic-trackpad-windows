<#
    Magic Trackpad for Windows - remove ALL known Apple / Magic Trackpad drivers
    ==========================================================================

    A "clean slate" cleanup for machines where a previous trackpad driver
    (Apple's own, an older MagicTrackpad2ForWindows build, a partially
    installed package, or a third-party utility's filter) is still in the way.
    Typical symptom it fixes: the control panel starts but reports

        Failed to open device. Error: 2

    because the driver's control device (\.\AmtPtpControlDeviceUm) does not
    exist - the trackpad is not actually bound to the driver.

    What it does
      1. finds every driver package whose INF matches the Apple / trackpad
         patterns (AmtPtpDevice*.inf, ApplePrecisionTrackpad*.inf,
         Apple*trackpad*.inf, MagicTrackpad*.inf),
      2. uninstalls those packages (pnputil /delete-driver ... /uninstall /force),
      3. removes leftover (ghost) device instances for the known Apple trackpad
         hardware IDs - VID_05AC PID_0265/0324/030E and VID_27A7 PID_2501/9601,
      4. stops and disables the AmtPtpHidFilter service if it is still around,
      5. reports known third-party trackpad utilities that hijack the device
         (Magic Utilities, Trackpad++) - uninstall those by hand,
      6. optionally removes the self-signed certificates (-IncludeCerts),
      7. re-scans PnP so Windows can re-detect the trackpad.

    Usage (from the extracted package):

        Uninstall-All-Apple-Drivers.cmd                  (double-click, UAC, does it)
        Uninstall-All-Apple-Drivers.cmd -DryRun          (only list what it would remove)
        Uninstall-All-Apple-Drivers.cmd -IncludeCerts    (also untrust our certificates)

    Nothing else on the machine is touched: only the patterns above and the
    Apple trackpad hardware IDs are considered. Keyboards, mice and other Apple
    devices are left alone.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$IncludeCerts
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-Step($t) { Write-Host "==> $t" -ForegroundColor Cyan }
function Write-Ok($t)   { Write-Host "    OK   $t" -ForegroundColor Green }
function Write-Info($t) { Write-Host "    $t" }
function Write-Warn2($t){ Write-Host "    WARN $t" -ForegroundColor Yellow }

# INF name patterns that belong to Apple / Magic Trackpad drivers
$infPatterns = @(
    '^amtptp.*\.inf$',
    '^appleprecisiontrackpad.*\.inf$',
    '^apple.*trackpad.*\.inf$',
    '^magictrackpad.*\.inf$'
)
# Hardware IDs of Apple Magic Trackpads. Device instance IDs are messy
# ("USB\VID_05AC&PID_0324\...", "HID\..._VID&0001004C_PID&0324&COL01\...",
# "USB\VID_27A7&PID_2501&MI_00\..."), so match vendor and product separately
# instead of trying to encode the separators. Apple keyboards (PID 1109) and
# every non-trackpad device are deliberately left alone.
$vendorPattern  = '05AC|27A7|0001004C'
$productPattern = '0265|0324|030E|2501|9601'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-ElevatedSelf {
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [switch]) { if ($kv.Value.IsPresent) { $argList += "-$($kv.Key)" } }
    }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
}

function Get-DriverPackages {
    $list = @()
    $published = $null
    $original = $null
    $provider = $null
    foreach ($line in (& pnputil.exe /enum-drivers)) {
        if ($line -match '^Published Name\s*:\s*(.+)$') {
            if ($published) { $list += [pscustomobject]@{ Published = $published; Original = $original; Provider = $provider } }
            $published = $Matches[1].Trim(); $original = ''; $provider = ''
        } elseif ($line -match '^Original Name\s*:\s*(.+)$') {
            $original = $Matches[1].Trim()
        } elseif ($line -match '^Provider Name\s*:\s*(.+)$') {
            $provider = $Matches[1].Trim()
        }
    }
    if ($published) { $list += [pscustomobject]@{ Published = $published; Original = $original; Provider = $provider } }
    return $list
}

function Get-TrackpadDevices {
    # one pass; matches by hardware ID only (fast and safe).
    # NOTE: no -PresentOnly here on purpose - ghosts of removed devices are
    # exactly what has to be cleaned up. (-All is not a valid switch on the
    # PowerShell 5.1 that ships with Windows 10.)
    return @(Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object {
            $_.InstanceId -match $vendorPattern -and $_.InstanceId -match $productPattern
        })
}

# ------------------------------------------------------------------ main

Write-Host ''
Write-Host 'Magic Trackpad - remove all known Apple trackpad drivers' -ForegroundColor White
if ($DryRun) { Write-Host '  (dry run: nothing will be changed)' -ForegroundColor Yellow }
Write-Host ''

if (-not (Test-Admin)) {
    if ($DryRun) { Write-Warn2 'dry run needs administrator rights too (reading the driver store)'; Invoke-ElevatedSelf; return }
    Invoke-ElevatedSelf
    return
}

$packages = Get-DriverPackages
$targets = @($packages | Where-Object {
    $n = $_.Original
    if (-not $n) { return $false }
    foreach ($p in $infPatterns) { if ($n -match $p) { return $true } }
    return $false
})

Write-Step 'driver packages that belong to Apple / Magic Trackpad drivers'
if ($targets.Count -eq 0) {
    Write-Info 'none found in the driver store'
} else {
    foreach ($t in $targets) {
        Write-Info ("{0,-12} {1,-34} {2}" -f $t.Published, $t.Original, $t.Provider)
    }
}

Write-Step 'trackpad device instances (present and ghost)'
$devices = Get-TrackpadDevices
if ($devices.Count -eq 0) {
    Write-Info 'none found'
} else {
    foreach ($d in $devices) {
        Write-Info ("{0,-10} {1,-12} {2}" -f $d.Status, $d.Class, $d.InstanceId)
    }
}

if (-not $DryRun) {
    # 1. uninstall the packages (this also unbinds them from devices)
    if ($targets.Count -gt 0) {
        Write-Step 'uninstalling driver packages'
        foreach ($t in $targets) {
            $out = & pnputil.exe /delete-driver $t.Published /uninstall /force 2>&1
            $out | ForEach-Object { Write-Info $_ }
            if ($LASTEXITCODE -eq 0) { Write-Ok "removed $($t.Published) ($($t.Original))" }
            else { Write-Warn2 "could not remove $($t.Published) - it may be in use; reboot and run this again" }
        }
    }

    # 2. remove leftover device instances so Windows re-detects cleanly
    if ($devices.Count -gt 0) {
        Write-Step 'removing leftover device instances'
        foreach ($d in $devices) {
            $out = & pnputil.exe /remove-device "$($d.InstanceId)" 2>&1
            $out | ForEach-Object { Write-Info $_ }
            if ($LASTEXITCODE -eq 0) { Write-Ok "removed $($d.InstanceId)" }
            else { Write-Warn2 "could not remove $($d.InstanceId) (it may be the device you are using right now)" }
        }
    }

    # 3. the filter service can survive a package removal on some machines
    $svc = Get-Service -Name 'AmtPtpHidFilter' -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Step 'removing the AmtPtpHidFilter service'
        if ($svc.Status -ne 'Stopped') { Stop-Service AmtPtpHidFilter -Force -ErrorAction SilentlyContinue }
        & sc.exe delete AmtPtpHidFilter | ForEach-Object { Write-Info $_ }
    }

    # 4. third-party tools that hijack the trackpad
    Write-Step 'known third-party trackpad tools'
    $found = @()
    foreach ($p in @('MagicUtilities','Magic Utilities','Trackpad++','TrackpadPlusPlus','TPPService','Trackpad++ Service')) {
        $procs = Get-Process -Name $p -ErrorAction SilentlyContinue
        if ($procs) { $found += "process: $p" }
        $s = Get-Service -Name $p -ErrorAction SilentlyContinue
        if ($s) { $found += "service: $p" }
    }
    $uninst = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match 'Magic Utilities|Trackpad\+\+' } | Select-Object -ExpandProperty DisplayName -Unique
    foreach ($u in $uninst) { $found += "installed: $u" }
    if ($found.Count -eq 0) { Write-Info 'none detected' }
    else {
        foreach ($f in $found) { Write-Warn2 $f }
        Write-Info 'uninstall those through Apps & features before installing this driver - they install their own filter and take the trackpad over'
    }

    # 5. optionally remove our certificates
    if ($IncludeCerts) {
        $certDir = Join-Path $root 'certs'
        if (Test-Path $certDir) {
            Write-Step 'removing the trusted certificates'
            foreach ($file in (Get-ChildItem -Path $certDir -Filter '*.cer' -File)) {
                $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($file.FullName)
                foreach ($storeName in @('Root','CA','TrustedPublisher')) {
                    try {
                        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($storeName,'LocalMachine')
                        $store.Open('ReadWrite'); $store.Remove($cert); $store.Close()
                    } catch { }
                }
                Write-Ok "untrusted $($cert.Subject)"
            }
        }
    }

    Write-Step 're-scanning devices'
    & pnputil.exe /scan-devices | Out-Null
    Start-Sleep -Seconds 3
    $after = Get-TrackpadDevices
    Write-Step 'trackpad devices after cleanup'
    if ($after.Count -eq 0) { Write-Info 'none (Windows will re-detect the trackpad when you plug it in again)' }
    else { foreach ($d in $after) { Write-Info ("{0,-10} {1,-12} {2}" -f $d.Status, $d.Class, $d.InstanceId) } }

    Write-Host ''
    Write-Host 'Cleanup finished.' -ForegroundColor Green
    Write-Host '  Next: unplug/replug the trackpad (or remove + re-pair Bluetooth), then run Install.cmd.'
    Write-Host '  If the panel still says "Failed to open device. Error: 2", send the device list printed above -'
    Write-Host '  it means the trackpad model is not covered by the driver INF yet.'
} else {
    Write-Host ''
    Write-Host 'Dry run finished - nothing was changed. Drop -DryRun to actually remove these.' -ForegroundColor Green
}
