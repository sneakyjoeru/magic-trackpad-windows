<#
.SYNOPSIS
  Non-interactive build of the Magic Trackpad 2 drivers + control panel,
  with self-signed code signing and inf2cat. Produces a ready-to-import
  driver package under <driver>\build\result\.

.DESCRIPTION
  Automates what build\make.bat does interactively (no prompts):
    1. Locates VS2022 (via vswhere) and the Windows SDK tools (signtool/inf2cat).
    2. Restores NuGet packages for both driver projects.
    3. Patches the restored WDK NuGet package so its post-build ApiValidator
       (WDK targets hardcode ...\bin\10.0.26100.0\x86\ApiValidator.exe,
       but the package only ships c\bin\...\{x64,ARM64}) — mirrors x64\ into x86\.
    4. Builds all targets (UsbUm + HidFilter for x64 [required] and ARM64 [best
       effort, needs the MSVC ARM64 CRT libs], control panel AnyCPU).
       /p:SpectreMitigation=false silences MSB8040 (WDK NuGet props + stock MSVC
       toolset mismatch); it does not affect driver correctness.
    5. Assembles the result tree (drivers, control panel, INFs, PDBs).
    6. Swaps in the Windows 10 INF for the AMD64 package (stock INF targets a Win11-era section).
    7. Creates (or reuses) a self-signed code-signing cert, trusts it (elevated import
       into LocalMachine\Root if possible), and signs all binaries + CATs.
    8. Runs inf2cat for AMD64 (10_X64) and ARM64 (10_RS3_ARM64).

  On success prints BUILD_COMPLETE and lists the result tree.

.PARAMETER RepoRoot
  Path to the repository root (the folder that contains driver\ and utility\).
  Defaults to the parent of the directory containing this script.

.PARAMETER NuGetExe
  Path to nuget.exe. Defaults to 'nuget.exe' resolved from PATH, then the
  script directory, then $env:USERPROFILE\nuget.exe.

.PARAMETER SkipArm64
  Build x64 only (skip the ARM64 driver targets).

.EXAMPLE
  .\Build-MtTrackpad.ps1
  # Builds from the repo's driver\ tree using nuget from PATH.

.EXAMPLE
  .\Build-MtTrackpad.ps1 -RepoRoot C:\src\magic-trackpad-windows -NuGetExe C:\tools\nuget.exe

.NOTES
  Can be run from a non-elevated PowerShell: the LocalMachine cert trust
  import is attempted with automatic elevation (RunAs). Requires VS2022 with
  the "Desktop development in C++" workload and the WDK MSBuild toolsets
  (Windows Driver Kit workload).
#>
param(
    [string]$RepoRoot,
    [string]$NuGetExe,
    [switch]$SkipArm64
)

$ErrorActionPreference = 'Stop'

# Resolve repo root (default: parent of this script's directory)
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $scriptDir
}
# Support both layouts: repo-style (<root>\driver\build) and raw upstream (<root>\build)
if (Test-Path (Join-Path $RepoRoot 'driver\build')) {
    $root = Join-Path $RepoRoot 'driver'
} elseif (Test-Path (Join-Path $RepoRoot 'build')) {
    $root = $RepoRoot
} else {
    $root = Join-Path $RepoRoot 'driver'
}
$build = Join-Path $root 'build'
if (-not (Test-Path $build)) { Write-Host "FAIL: build dir not found at $build"; exit 1 }
Set-Location $build
Write-Host "ROOT: $root"

# Resolve nuget.exe
if (-not $NuGetExe) {
    $cmd = Get-Command nuget.exe -ErrorAction SilentlyContinue
    if ($cmd) { $NuGetExe = $cmd.Source }
    elseif (Test-Path (Join-Path $scriptDir 'nuget.exe')) { $NuGetExe = Join-Path $scriptDir 'nuget.exe' }
    elseif (Test-Path (Join-Path $env:USERPROFILE 'nuget.exe')) { $NuGetExe = Join-Path $env:USERPROFILE 'nuget.exe' }
}
if (-not $NuGetExe -or -not (Test-Path $NuGetExe)) { Write-Host "FAIL: nuget.exe not found"; exit 1 }
Write-Host "nuget: $NuGetExe"

# 1) Locate VS2022
$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { Write-Host "FAIL: vswhere not found"; exit 1 }
$vsPath = & $vswhere -latest -products * -property installationPath
Write-Host "VS: $vsPath"
if (-not $vsPath) { Write-Host "FAIL: VS not installed"; exit 1 }

# 2) NuGet restore (packages -> <root>\packages\) — must run BEFORE WDK package patching
& $NuGetExe restore "$root\AmtPtpHidFilter\packages.config" -PackagesDirectory "$root\packages\"
if ($LASTEXITCODE -ne 0) { Write-Host "FAIL: nuget restore HidFilter"; exit 1 }
& $NuGetExe restore "$root\AmtPtpDeviceUsbUm\packages.config" -PackagesDirectory "$root\packages\"
if ($LASTEXITCODE -ne 0) { Write-Host "FAIL: nuget restore UsbUm"; exit 1 }

# 2b) Reference assemblies for the control panel (.NET 4.7.2). The build machine may lack
#     the .NET Framework Developer Pack (=> MSB3644); the NuGet reference-assemblies
#     net472 flavor provides them. TargetFrameworkRootPath must point at the package's
#     build\ root — MSBuild appends .NETFramework\v4.7.2\ itself.
$refAsmOut = Join-Path $root 'packages\dotnet-refassemblies'
& $NuGetExe install Microsoft.NETFramework.ReferenceAssemblies.net472 -Version 1.0.3 -OutputDirectory $refAsmOut
if ($LASTEXITCODE -ne 0) { Write-Host "FAIL: nuget install Microsoft.NETFramework.ReferenceAssemblies.net472"; exit 1 }
$refAsmRoot = Join-Path $refAsmOut 'Microsoft.NETFramework.ReferenceAssemblies.net472.1.0.3\build'
$v472Dir = Join-Path $refAsmRoot '.NETFramework\v4.7.2'
if (-not (Test-Path $v472Dir)) {
    $pkgDir = Get-ChildItem $refAsmOut -Directory -Filter 'Microsoft.NETFramework.ReferenceAssemblies.net472.*' | Select-Object -First 1
    if ($pkgDir) { $refAsmRoot = Join-Path $pkgDir.FullName 'build'; $v472Dir = Join-Path $refAsmRoot '.NETFramework\v4.7.2' }
}
if (-not (Test-Path $v472Dir)) { Write-Host "FAIL: .NET 4.7.2 reference assemblies not found under $refAsmOut"; exit 1 }
Write-Host "refassemblies: $refAsmRoot"

# 3) Patch the WDK NuGet package: the WDK MSBuild targets hardcode the ApiValidator
#    path ...WDK.x64.10.0.26100.6584\c\bin\10.0.26100.0\x86\ApiValidator.exe, but the
#    package only contains c\bin\10.0.26100.0\{x64,ARM64}. Mirror x64\ into x86\
#    (the x64 apivalidator + its runtime deps run fine on an x64 machine).
$wdkPkg = Get-ChildItem "$root\packages" -Directory -Filter 'Microsoft.Windows.WDK.x64.*' | Select-Object -First 1
if ($wdkPkg) {
    $wdkBinVer = Join-Path $wdkPkg.FullName 'c\bin\10.0.26100.0'
    $x64Bin = Join-Path $wdkBinVer 'x64'
    $x86Bin = Join-Path $wdkBinVer 'x86'
    if ((Test-Path $x64Bin) -and (Test-Path $x86Bin)) {
        $srcApival = Join-Path $x64Bin 'apivalidator.exe'
        $dstApival = Join-Path $x86Bin 'ApiValidator.exe'
        if ((Test-Path $srcApival) -and -not (Test-Path $dstApival)) {
            Copy-Item "$x64Bin\*" $x86Bin -Force
            Write-Host "WDK_PATCH: mirrored $x64Bin -> $x86Bin (ApiValidator fix)"
        } else {
            Write-Host "WDK_PATCH: already applied"
        }
        Write-Host "inf2cat candidate: $(Join-Path $x86Bin 'Inf2Cat.exe')"
    }
}

# 4) Locate inf2cat (prefer the installed SDK; the WDK package copy is a fallback)
#    + signtool (installed SDK; prefer the x64 copy on an x64 machine).
$sdkInf = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse -Filter inf2cat.exe -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match 'x86' } | Select-Object -First 1
$pkgInf = Get-ChildItem "$root\packages" -Recurse -Filter 'Inf2Cat.exe' -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match 'x86' } | Select-Object -First 1
$inf2cat = $null
if ($sdkInf) { $inf2cat = $sdkInf.FullName }
elseif ($pkgInf) { $inf2cat = $pkgInf.FullName }
$sdkSig = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match 'x64' } | Select-Object -First 1
if (-not $sdkSig) {
    $sdkSig = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match 'x86' } | Select-Object -First 1
}
$signtool = $sdkSig.FullName
Write-Host "inf2cat: $inf2cat"
Write-Host "signtool: $signtool"
if (-not $inf2cat -or -not (Test-Path $signtool)) { Write-Host "FAIL: SDK tools not found"; exit 1 }

# 5) Locate msbuild from VS
$msbuild = & $vswhere -latest -products * -find MSBuild\**\Bin\MSBuild.exe | Select-Object -First 1
Write-Host "msbuild: $msbuild"
if (-not $msbuild) { Write-Host "FAIL: msbuild not found"; exit 1 }

function Invoke-MtBuild {
    param([string]$Project, [string]$Platform, [bool]$Required, [string[]]$ExtraProps = @())
    Write-Host "=== BUILD $Project [$Platform]"
    $mbArgs = @($Project, '/p:Configuration=Release', "/p:Platform=$Platform",
                '/p:SpectreMitigation=false', '/p:TargetPlatformVersion=10.0.26100.0',
                '/m', '/nologo', '/v:m')
    foreach ($ep in $ExtraProps) { $mbArgs += $ep }
    & $msbuild @mbArgs
    if ($LASTEXITCODE -ne 0) {
        if ($Required) { Write-Host "FAIL: build $Project $Platform"; exit 1 }
        Write-Host "WARN: build $Project $Platform failed (best effort)"
    }
}

# 6) Build all targets (same as make.bat, minus prompts; ARM64 is best-effort)
Invoke-MtBuild "$root\AmtPtpDeviceUsbUm\MagicTrackpad2PtpDevice.vcxproj" 'x64' $true
Invoke-MtBuild "$root\AmtPtpHidFilter\AmtPtpHidFilter.vcxproj" 'x64' $true
if (-not $SkipArm64) {
    Invoke-MtBuild "$root\AmtPtpDeviceUsbUm\MagicTrackpad2PtpDevice.vcxproj" 'ARM64' $false
    Invoke-MtBuild "$root\AmtPtpHidFilter\AmtPtpHidFilter.vcxproj" 'ARM64' $false
}
Invoke-MtBuild "$root\AmtPtpControlPanel\AmtPtpControlPanel.csproj" 'AnyCPU' $true `
    -ExtraProps @("/p:TargetFrameworkRootPath=$refAsmRoot\")
Write-Host "BUILD_ALL_OK"

# 7) Assemble result tree (same as make.bat; ARM64 files only if built)
$result = Join-Path $build 'result'
if (Test-Path $result) { Remove-Item $result -Recurse -Force }
New-Item -ItemType Directory -Path "$result\AMD64", "$result\ARM64", "$result\pdb\AMD64", "$result\pdb\ARM64" | Out-Null

Copy-Item "AmtPtpDevice_AMD64.inf" "$result\AMD64\AmtPtpDevice.inf"
Copy-Item "AmtPtpDevice_ARM64.inf" "$result\ARM64\AmtPtpDevice.inf"
$cpExe = Get-ChildItem "$root\AmtPtpControlPanel\bin\Release" -Filter 'AmtPtpControlPanel.exe' -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($cpExe) { Copy-Item $cpExe.FullName $result } else { Write-Host "WARN: control panel exe not found" }

$arm64Files = @(
    "$root\AmtPtpDeviceUsbUm\build\AmtPtpDeviceUsbUm\ARM64\Release\AmtPtpDeviceUsbUm.dll",
    "$root\AmtPtpHidFilter\build\AmtPtpHidFilter\ARM64\Release\AmtPtpHidFilter.sys"
)
foreach ($f in $arm64Files) {
    if (Test-Path $f) {
        Copy-Item $f "$result\ARM64"
    } else {
        Write-Host "WARN: missing $f (ARM64 package will be empty)"
    }
}
Copy-Item "$root\AmtPtpDeviceUsbUm\build\AmtPtpDeviceUsbUm\x64\Release\AmtPtpDeviceUsbUm.dll" "$result\AMD64"
Copy-Item "$root\AmtPtpHidFilter\build\AmtPtpHidFilter\x64\Release\AmtPtpHidFilter.sys" "$result\AMD64"

$pdbFiles = @(
    @("$root\AmtPtpDeviceUsbUm\build\AmtPtpDeviceUsbUm\x64\Release\AmtPtpDeviceUsbUm.pdb", 'AMD64'),
    @("$root\AmtPtpHidFilter\build\AmtPtpHidFilter\x64\Release\AmtPtpHidFilter.pdb", 'AMD64'),
    @("$root\AmtPtpDeviceUsbUm\build\AmtPtpDeviceUsbUm\ARM64\Release\AmtPtpDeviceUsbUm.pdb", 'ARM64'),
    @("$root\AmtPtpHidFilter\build\AmtPtpHidFilter\ARM64\Release\AmtPtpHidFilter.pdb", 'ARM64')
)
foreach ($p in $pdbFiles) {
    if (Test-Path $p[0]) { Copy-Item $p[0] "$result\pdb\$($p[1])" }
}

# 8) Swap in WIN10-compatible INF for AMD64 (stock INF uses Win11-era section range)
$win10Inf = Get-ChildItem $build -Filter '*WIN10*.inf' | Select-Object -First 1
if ($win10Inf) {
    Copy-Item $win10Inf.FullName "$result\AMD64\AmtPtpDevice.inf" -Force
    Write-Host "SWAPPED_INF: $($win10Inf.Name)"
} else {
    Write-Host "WARN: no WIN10 INF found, using stock AMD64 INF"
}

# 9) Code-signing cert: import the pre-generated keypair if absent, then sign everything with it.
#    The keypair is pre-generated with openssl (KeyUsage=critical,digitalSignature +
#    EKU=codeSigning) because PS 5.1's New-SelfSignedCertificate stamps a TLS EKU,
#    which signtool rejects.
$pfxPath = Join-Path $scriptDir 'certs\MtTrackpad.pfx'
if (-not (Test-Path $pfxPath)) { Write-Host "FAIL: $pfxPath not found"; exit 1 }
$pwd = ConvertTo-SecureString 'mttrackpad' -AsPlainText -Force
$probe = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($pfxPath, $pwd)
$thumbprint = $probe.Thumbprint
$probeStore = New-Object System.Security.Cryptography.X509Certificates.X509Store('My', 'CurrentUser')
$probeStore.Open('ReadOnly')
$haveIt = $false
foreach ($c in $probeStore.Certificates) { if ($c.Thumbprint -eq $thumbprint) { $haveIt = $true; break } }
$probeStore.Close()
if ($haveIt) {
    # Export .cer for the package (public cert only)
    [IO.File]::WriteAllBytes("$result\MtTrackpad.cer", $probe.RawData)
    Write-Host "CERT_EXISTS: $thumbprint"
} else {
    $pfxCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($pfxPath, $pwd, ([System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKey -bor [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::UserKeyStore))
    $newStore = New-Object System.Security.Cryptography.X509Certificates.X509Store('My', 'CurrentUser')
    $newStore.Open('ReadWrite')
    $newStore.Add($pfxCert)
    $newStore.Close()
    # Export .cer for the package (public cert only; the private key stays in CurrentUser\My)
    [IO.File]::WriteAllBytes("$result\MtTrackpad.cer", $pfxCert.Export('CERT'))
    Write-Host "CERT_CREATED: $thumbprint"
}

# Trust the cert: try LocalMachine\Root directly (works when elevated),
# otherwise spawn an elevated child to import it (UAC prompt may flash briefly).
$cerPath = "$result\MtTrackpad.cer"
$trustedBefore = @(Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $thumbprint }).Count
if ($trustedBefore -eq 0) {
    try {
        Import-Certificate -FilePath $cerPath -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
        Write-Host "CERT_TRUSTED (direct)"
    } catch {
        Write-Host "ELEVATING for LocalMachine\Root import..."
        try {
            $impScript = Join-Path $env:TEMP 'Import-MtCert.ps1'
            $cerEsc = $cerPath.Replace("'", "''")
            @"
`$cer = '$cerEsc'
Import-Certificate -FilePath `$cer -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
Import-Certificate -FilePath `$cer -CertStoreLocation Cert:\LocalMachine\My | Out-Null
"@ | Set-Content -Path $impScript -Encoding ASCII
            $wp = Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$impScript`"" -PassThrust
            $wp.WaitForExit(60000)
        } catch {
            Write-Host "WARN: elevation failed ($($_.Exception.Message)); cert will be imported during driver install"
        }
    }
    $trustedAfter = @(Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $thumbprint }).Count
    if ($trustedAfter -gt 0) { Write-Host "CERT_TRUSTED (verified)" }
    else { Write-Host "WARN: cert not yet in LocalMachine\Root (import it before driver install)" }
} else {
    Write-Host "CERT_ALREADY_TRUSTED"
}

# 10) Sign (self-signed => no digicert timestamp; plain /fd sha256)
$sign = @(
    "$result\AmtPtpControlPanel.exe",
    "$result\AMD64\AmtPtpDeviceUsbUm.dll",
    "$result\AMD64\AmtPtpHidFilter.sys"
)
if (Test-Path "$result\ARM64\AmtPtpDeviceUsbUm.dll") { $sign += "$result\ARM64\AmtPtpDeviceUsbUm.dll" }
if (Test-Path "$result\ARM64\AmtPtpHidFilter.sys") { $sign += "$result\ARM64\AmtPtpHidFilter.sys" }
foreach ($f in $sign) {
    Write-Host "SIGNING $f"
    & $signtool sign /fd sha256 /f $pfxPath /p mttrackpad $f
    if ($LASTEXITCODE -ne 0) { Write-Host "FAIL: sign $f"; exit 1 }
}

# 11) inf2cat + sign CAT (AMD64 always; ARM64 only if the package has binaries)
& $inf2cat /driver:$result\AMD64 /os:10_X64
if ($LASTEXITCODE -ne 0) { Write-Host "FAIL: inf2cat AMD64"; exit 1 }
& $signtool sign /fd sha256 /f $pfxPath /p mttrackpad "$result\AMD64\AmtPtpDevice.cat"
if ($LASTEXITCODE -ne 0) { Write-Host "FAIL: sign cat AMD64"; exit 1 }
if ((Get-ChildItem "$result\ARM64" -Filter '*.dll' -ErrorAction SilentlyContinue) -or (Get-ChildItem "$result\ARM64" -Filter '*.sys' -ErrorAction SilentlyContinue)) {
    & $inf2cat /driver:$result\ARM64 /os:10_RS3_ARM64
    if ($LASTEXITCODE -ne 0) { Write-Host "FAIL: inf2cat ARM64"; exit 1 }
    & $signtool sign /fd sha256 /f $pfxPath /p mttrackpad "$result\ARM64\AmtPtpDevice.cat"
    if ($LASTEXITCODE -ne 0) { Write-Host "FAIL: sign cat ARM64"; exit 1 }
}

Write-Host "RESULT:"
Get-ChildItem $result -Recurse | Select-Object FullName, Length | Format-Table | Out-String
Write-Host "BUILD_COMPLETE"
