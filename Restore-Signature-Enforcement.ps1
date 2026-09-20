<#
    Magic Trackpad for Windows - restore normal driver signature enforcement
    =======================================================================

    Turns Windows test signing back OFF (it is only needed for the
    self-signed driver variant used by VID 27A7 clones) and reports the state.

        Restore-Signature-Enforcement.cmd      (double-click, one UAC prompt)
        Restore-Signature-Enforcement.cmd -DryRun   (only show the current state)

    A reboot is required for the change to take effect. Secure Boot can only be
    re-enabled in the machine's UEFI/BIOS setup (it is not an OS setting) - the
    script tells you whether it looks enabled.
#>
[CmdletBinding()]
param([switch]$DryRun)

$ErrorActionPreference = 'Continue'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-TestSigningState {
    $out = @(& bcdedit.exe /enum '{current}' 2>$null)
    $line = @($out | Select-String 'testsigning')
    if ($line.Count -gt 0) { return ($line[0].ToString() -replace '\s+', ' ').Trim() }
    return 'testsigning not set (default: off)'
}

function Get-SecureBootState {
    try { return (Confirm-SecureBootUEFI) } catch { return 'cannot query (not elevated, or legacy BIOS)' }
}

Write-Host ''
Write-Host 'Magic Trackpad - restore driver signature enforcement' -ForegroundColor White
Write-Host ''
Write-Host ("before : " + (Get-TestSigningState))
Write-Host ("secure boot : " + (Get-SecureBootState))

if (-not (Test-Admin)) {
    if ($DryRun) { Write-Host ''; Write-Host 'Dry run needs no elevation for this much.'; exit 0 }
    Write-Host ''
    Write-Host 'Restarting with administrator rights (needed to change the boot configuration)...'
    $args2 = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $args2
    exit 0
}

if ($DryRun) {
    Write-Host ''
    Write-Host 'Dry run: nothing changed. Drop -DryRun to turn test signing off.' -ForegroundColor Green
    exit 0
}

Write-Host ''
Write-Host 'turning test signing off ...'
& bcdedit.exe /set testsigning off
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host 'FAILED - bcdedit refused. On a machine with Secure Boot enabled the value is'
    Write-Host 'protected: disable Secure Boot in the UEFI/BIOS setup first, or leave it as is.'
    exit 1
}
Write-Host ("after  : " + (Get-TestSigningState))

Write-Host ''
Write-Host 'Done. REBOOT the machine for it to take effect - the "Test Mode" watermark' -ForegroundColor Green
Write-Host 'disappears and only properly signed drivers may load from then on.' -ForegroundColor Green
Write-Host ''
Write-Host 'Notes:'
Write-Host '  * Secure Boot can only be switched back on in the UEFI/BIOS setup.'
Write-Host '  * The Microsoft-signed driver (what this package installs by default) works'
Write-Host '    with enforcement on. A self-signed driver would stop loading - only needed'
Write-Host '    for VID 27A7 clones.'
