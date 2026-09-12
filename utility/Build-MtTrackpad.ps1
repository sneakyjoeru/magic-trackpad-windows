<#
.SYNOPSIS
  Non-interactive build of the Magic Trackpad 2 drivers + control panel,
  with self-signed code signing and inf2cat. Produces a ready-to-import
  driver package under <driver>\build\result\.

.DESCRIPTION
  Automates what build\make.bat does interactively (no prompts):
    1. Locates VS2022 (via vswhere) and the Windows SDK tools (inf2cat/signtool).
    2. Restores NuGet packages for both driver projects.
    3. Builds all targets (UsbUm + HidFilter for ARM64/x64, control panel AnyCPU).
    4. Assembles the result tree (drivers, control panel, INFs, PDBs).
    5. Swaps in the Windows 10 INF for the AMD64 package (stock INF targets a Win11-era section).
    6. Creates (or reuses) a self-signed code-signing cert, trusts it, and signs all binaries + CATs.
    7. Runs inf2cat for AMD64 (10_X64) and ARM64 (10_RS3_ARM64).

  On success prints BUILD_COMPLETE and lists the result tree.

.PARAMETER RepoRoot
  Path to the repository root (the folder that contains driver\ and utility\).
  Defaults to the parent of the directory containing this script.

.PARAMETER NuGetExe
  Path to nuget.exe. Defaults to 'nuget.exe' resolved from PATH, then the script directory.

.EXAMPLE
  .\Build-MtTrackpad.ps1
  # Builds from the repo's driver\ tree using nuget from PATH.

.EXAMPLE
  .\Build-MtTrackpad.ps1 -RepoRoot C:\src\magic-trackpad-windows -NuGetExe C:\tools\nuget.exe

.NOTES
  Run from an elevated PowerShell. Requires VS2022 with the "Desktop development in C++"
  and "Windows Driver Kit" workloads installed.
#>
param(
    [string]$RepoRoot,
    [string]$NuGetExe
)

$ErrorActionPreference = 'Stop'

# Resolve repo root (default: parent of this script's directory)
if (-not $RepoRoot) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $RepoRoot = Split-Path -Parent $scriptDir
}
$root = Join-Path $RepoRoot 'driver'
$build = Join-Path $root 'build'
if (-not (Test-Path $build)) { Write-Host "FAIL: build dir not found at $build"; exit 1 }
Set-Location $build
Write-Host "ROOT: $root"

# Resolve nuget.exe
if (-not $NuGetExe) {
    $cmd = Get-Command nuget.exe -ErrorAction SilentlyContinue
    if ($cmd) { $NuGetExe = $cmd.Source }
    elseif (Test-Path (Join-Path $scriptDir 'nuget.exe')) { $NuGetExe = Join-Path $scriptDir 'nuget.exe' }
}
if (-not $NuGetExe -or -not (Test-Path $NuGetExe)) { Write-Host "FAIL: nuget.exe not found"; exit 1 }
Write-Host "nuget: $NuGetExe"

# 1) Locate VS2022 + inf2cat
$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { Write-Host "FAIL: vswhere not found"; exit 1 }
$vsPath = & $vswhere -latest -products * -property installationPath
Write-Host "VS: $vsPath"
if (-not $vsPath) { Write-Host "FAIL: VS not installed"; exit 1 }

$sdkBin = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse -Filter inf2cat.exe -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match 'x86' } | Select-Object -First 1
$inf2cat = $sdkBin.FullName
$signtool = Join-Path $sdkBin.DirectoryName 'signtool.exe'
Write-Host "inf2cat: $inf2cat"
Write-Host "signtool: $signtool"
if (-not $inf2cat -or -not (Test-Path $signtool)) { Write-Host "FAIL: SDK tools not found"; exit 1 }

# 2) NuGet restore (packages -> ..\packages\)
& $NuGetExe restore "$root\AmtPtpHidFilter\packages.config" -PackagesDirectory "$root\packages\"
if ($LASTEXITCODE -ne 0) { Write-Host "FAIL: nuget restore HidFilter"; exit 1 }
& $NuGetExe restore "$root\AmtPtpDeviceUsbUm\packages.config" -PackagesDirectory "$root\packages\"
if ($LASTEXITCODE -ne 0) { Write-Host "FAIL: nuget restore UsbUm"; exit 1 }

# 3) Locate msbuild from VS
$msbuild = & $vswhere -latest -products * -find MSBuild\**\Bin\MSBuild.exe | Select-Object -First 1
Write-Host "msbuild: $msbuild"
if (-not $msbuild) { Write-Host "FAIL: msbuild not found"; exit 1 }

# 4) Build all targets (same as make.bat, minus prompts)
$targets = @(
    @("$root\AmtPtpDeviceUsbUm\MagicTrackpad2PtpDevice.vcxproj", 'ARM64'),
    @("$root\AmtPtpDeviceUsbUm\MagicTrackpad2PtpDevice.vcxproj", 'x64'),
    @("$root\AmtPtpHidFilter\AmtPtpHidFilter.vcxproj", 'ARM64'),
    @("$root\AmtPtpHidFilter\AmtPtpHidFilter.vcxproj", 'x64'),
    @("$root\AmtPtpControlPanel\AmtPtpControlPanel.csproj", 'AnyCPU')
)
foreach ($t in $targets) {
    Write-Host "=== BUILD $($t[0]) [$($t[1])]"
    & $msbuild $t[0] /p:Configuration=Release /p:Platform=$($t[1]) /m /nologo /v:m
    if ($LASTEXITCODE -ne 0) { Write-Host "FAIL: build $($t[0]) $($t[1])"; exit 1 }
}
Write-Host "BUILD_ALL_OK"

# 5) Assemble result tree (same as make.bat)
$result = Join-Path $build 'result'
if (Test-Path $result) { Remove-Item $result -Recurse -Force }
New-Item -ItemType Directory -Path "$result\AMD64", "$result\ARM64", "$result\pdb\AMD64", "$result\pdb\ARM64" | Out-Null

Copy-Item "AmtPtpDevice_AMD64.inf" "$result\AMD64\AmtPtpDevice.inf"
Copy-Item "AmtPtpDevice_ARM64.inf" "$result\ARM64\AmtPtpDevice.inf"
Copy-Item "$root\AmtPtpControlPanel\bin\Release\AmtPtpControlPanel.exe" $result
Copy-Item "$root\AmtPtpDeviceUsbUm\build\AmtPtpDeviceUsbUm\x64\Release\AmtPtpDeviceUsbUm.dll" "$result\AMD64"
Copy-Item "$root\AmtPtpDeviceUsbUm\build\AmtPtpDeviceUsbUm\ARM64\Release\AmtPtpDeviceUsbUm.dll" "$result\ARM64"
Copy-Item "$root\AmtPtpHidFilter\build\AmtPtpHidFilter\x64\Release\AmtPtpHidFilter.sys" "$result\AMD64"
Copy-Item "$root\AmtPtpHidFilter\build\AmtPtpHidFilter\ARM64\Release\AmtPtpHidFilter.sys" "$result\ARM64"
Copy-Item "$root\AmtPtpDeviceUsbUm\build\AmtPtpDeviceUsbUm\x64\Release\AmtPtpDeviceUsbUm.pdb" "$result\pdb\AMD64"
Copy-Item "$root\AmtPtpDeviceUsbUm\build\AmtPtpDeviceUsbUm\ARM64\Release\AmtPtpDeviceUsbUm.pdb" "$result\pdb\ARM64"
Copy-Item "$root\AmtPtpHidFilter\build\AmtPtpHidFilter\x64\Release\AmtPtpHidFilter.pdb" "$result\pdb\AMD64"
Copy-Item "$root\AmtPtpHidFilter\build\AmtPtpHidFilter\ARM64\Release\AmtPtpHidFilter.pdb" "$result\pdb\ARM64"

# 6) Swap in WIN10-compatible INF for AMD64 (stock INF uses Win11-era section range)
$win10Inf = Get-ChildItem $build -Filter '*WIN10*.inf' | Select-Object -First 1
if ($win10Inf) {
    Copy-Item $win10Inf.FullName "$result\AMD64\AmtPtpDevice.inf" -Force
    Write-Host "SWAPPED_INF: $($win10Inf.Name)"
} else {
    Write-Host "WARN: no WIN10 INF found, using stock AMD64 INF"
}

# 7) Self-signed cert (create if absent), then sign everything with it
$thumbprint = (Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.FriendlyName -eq 'MtTrackpadBuild' } | Select-Object -First 1).Thumbprint
if (-not $thumbprint) {
    $cert = New-SelfSignedCertificate -CertStoreLocation Cert:\CurrentUser\My -FriendlyName 'MtTrackpadBuild' `
        -KeyUsage CertSign -KeyAlgorithm RSA -KeyLength 2048 -MonthsWithNotAfter 36
    $thumbprint = $cert.Thumbprint
    # Export .cer for the package
    $bytes = [System.IO.File]::ReadAllBytes($cert.CertExport('CERT'))
    [IO.File]::WriteAllBytes("$result\MtTrackpad.cer", $bytes)
    Write-Host "CERT_CREATED: $thumbprint"
    # Make the self-signed cert trusted so the driver signature validates
    Import-Certificate -FilePath "$result\MtTrackpad.cer" -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
    Import-Certificate -FilePath "$result\MtTrackpad.cer" -CertStoreLocation Cert:\LocalMachine\My | Out-Null
    Write-Host "CERT_TRUSTED"
} else {
    $certObj = Get-Item "Cert:\CurrentUser\My\$thumbprint"
    $bytes = [System.IO.File]::ReadAllBytes($certObj.CertExport('CERT'))
    [IO.File]::WriteAllBytes("$result\MtTrackpad.cer", $bytes)
    Write-Host "CERT_EXISTS: $thumbprint"
}

# 8) Sign (self-signed => no digicert timestamp; plain /fd sha256)
$sign = @(
    "$result\AmtPtpControlPanel.exe",
    "$result\AMD64\AmtPtpDeviceUsbUm.dll",
    "$result\ARM64\AmtPtpDeviceUsbUm.dll",
    "$result\AMD64\AmtPtpHidFilter.sys",
    "$result\ARM64\AmtPtpHidFilter.sys"
)
foreach ($f in $sign) {
    Write-Host "SIGNING $f"
    & $signtool sign /fd sha256 /sha1 $thumbprint $f
    if ($LASTEXITCODE -ne 0) { Write-Host "FAIL: sign $f"; exit 1 }
}

# 9) inf2cat + sign CAT
& $inf2cat /driver:$result\AMD64 /os:10_X64
if ($LASTEXITCODE -ne 0) { Write-Host "FAIL: inf2cat AMD64"; exit 1 }
& $inf2cat /driver:$result\ARM64 /os:10_RS3_ARM64
if ($LASTEXITCODE -ne 0) { Write-Host "FAIL: inf2cat ARM64"; exit 1 }
& $signtool sign /fd sha256 /sha1 $thumbprint "$result\AMD64\AmtPtpDevice.cat"
if ($LASTEXITCODE -ne 0) { Write-Host "FAIL: sign cat AMD64"; exit 1 }
& $signtool sign /fd sha256 /sha1 $thumbprint "$result\ARM64\AmtPtpDevice.cat"
if ($LASTEXITCODE -ne 0) { Write-Host "FAIL: sign cat ARM64"; exit 1 }

Write-Host "RESULT:"
Get-ChildItem $result -Recurse | Select-Object FullName, Length | Format-Table | Out-String
Write-Host "BUILD_COMPLETE"
