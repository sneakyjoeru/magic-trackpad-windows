<#
    Magic Trackpad for Windows - diagnostics
    ========================================

    Collects everything needed to explain "the panel does not show up", "no
    tray icon", "no battery" or "Failed to open device. Error: 2" into one text
    file next to this script (MagicTrackpad-diagnose.txt).

    Read-only: it changes nothing. Run it by double-clicking Diagnose.cmd, or:

        powershell -ExecutionPolicy Bypass -File .\Diagnose.ps1
#>
[CmdletBinding()]
param(
    [string]$OutFile
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $OutFile) { $OutFile = Join-Path $root 'MagicTrackpad-diagnose.txt' }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

$out = New-Object System.Collections.Generic.List[string]
function Add-Line($t) { $out.Add([string]$t) | Out-Null }

function Add-Section($title) {
    Add-Line ''
    Add-Line ('=' * 70)
    Add-Line $title
    Add-Line ('=' * 70)
}

function Add-Cmd($label, $block) {
    Add-Line "--- $label"
    try { & $block 2>&1 | ForEach-Object { Add-Line ("    " + $_) } }
    catch { Add-Line ("    ERROR: " + $_.Exception.Message) }
}

# ---------------------------------------------------------------- header
Add-Section 'Magic Trackpad control panel - diagnostics'
Add-Line ("collected     : " + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
Add-Line ("computer      : " + $env:COMPUTERNAME + "   user: " + $env:USERNAME)
Add-Line ("elevated      : " + (Test-Admin))
Add-Line ("package folder: " + $root)

Add-Section 'Windows'
Add-Cmd 'version' {
    $k = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    "$($k.ProductName) $($k.DisplayVersion) build $($k.CurrentBuild).$($k.UBR)"
    "installed on  : $($k.InstallDate)"
}
Add-Cmd 'secure boot / test signing' {
    try { "SecureBoot: " + (Confirm-SecureBootUEFI) } catch { "SecureBoot: unknown ($($_.Exception.Message))" }
    "bcdedit testsigning: " + ((bcdedit /enum '{current}' 2>$null | Select-String 'testsigning').ToString().Trim())
}

Add-Section 'control panel process'
Add-Cmd 'processes' {
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='AmtPtpControlPanel.exe'" -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { 'none running - the panel is NOT running (start it with the Start Menu shortcut or Install.cmd)' }
    foreach ($p in $procs) {
        "pid $($p.ProcessId)  session $($p.SessionId)  started $($p.CreationDate)"
        "    cmd: $($p.CommandLine)"
    }
}
Add-Cmd 'windows of that process (visible?)' {
    $src = @'
using System;using System.Text;using System.Collections.Generic;using System.Runtime.InteropServices;
public class MtW {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  public static List<string> Wins(uint pid) {
    List<string> res = new List<string>();
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p == pid) {
        StringBuilder t = new StringBuilder(256); GetWindowText(h, t, 256);
        if (t.Length > 0) {
          RECT r; GetWindowRect(h, out r);
          res.Add("visible=" + IsWindowVisible(h) + "  at " + r.L + "," + r.T + " size " + (r.R-r.L) + "x" + (r.B-r.T) + "  '" + t.ToString() + "'");
        }
      }
      return true;
    }, IntPtr.Zero);
    return res;
  }
}
'@
    try { if (-not ('MtW' -as [type])) { Add-Type -TypeDefinition $src | Out-Null } } catch { 'Add-Type failed'; return }
    $pid2 = @(Get-CimInstance Win32_Process -Filter "Name='AmtPtpControlPanel.exe'" -ErrorAction SilentlyContinue | ForEach-Object { [uint32]$_.ProcessId })
    if ($pid2.Count -eq 0) { 'no process, no window' }
    foreach ($id in $pid2) {
        $w = @([MtW]::Wins($id))
        if ($w.Count -eq 0) { "pid $id : no top-level window" } else { foreach ($x in $w) { "pid $id : $x" } }
    }
    'A hidden window means the panel is running tray-only: the tray icon (or the show-event) brings it back.'
    'No window at all + a running process = it started hidden or the window failed to create.'
}
Add-Cmd 'panel error log' {
    $log = Join-Path $env:LOCALAPPDATA 'MagicTrackpad\panel-error.log'
    if (Test-Path $log) { "file: $log"; Get-Content $log -Tail 40 } else { "no error log at $log (good)" }
}

Add-Section 'settings and autostart (HKCU)'
Add-Cmd 'HKCU\Software\MtTrackpad\Tray' {
    $k = Get-ItemProperty 'HKCU:\Software\MtTrackpad\Tray' -ErrorAction SilentlyContinue
    if (-not $k) { 'key not present (defaults: ShowBattery=1, AutoStart=0, StartMin=0)' }
    else { "ShowBattery=$($k.ShowBattery)  AutoStart=$($k.AutoStart)  StartMin=$($k.StartMin)" }
}
Add-Cmd 'run key' {
    $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Magic Trackpad' -ErrorAction SilentlyContinue).'Magic Trackpad'
    if ($v) { "HKCU Run 'Magic Trackpad' = $v" } else { "no HKCU Run entry (autostart off)" }
}
Add-Cmd 'installed panel copies' {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'MagicTrackpad\AmtPtpControlPanel.exe'),
        "$env:USERPROFILE\Desktop\Magic Trackpad\UTILITY\AmtPtpControlPanel.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) {
            $i = Get-Item $c
            "found $c  ($($i.Length) bytes, $($i.LastWriteTime))  md5=$((Get-FileHash $c -Algorithm MD5).Hash)"
        } else { "missing $c" }
    }
}

Add-Section 'driver and devices'
Add-Cmd 'driver packages (Apple / trackpad)' {
    $lines = @(& pnputil.exe /enum-drivers 2>$null)
    $published = ''
    $found = $false
    foreach ($line in $lines) {
        if (-not $line) { continue }
        $m = [regex]::Match($line, '^Published Name\s*:\s*(.+)$')
        if ($m.Success) { $published = $m.Groups[1].Value.Trim(); continue }
        $m = [regex]::Match($line, '^Original Name\s*:\s*(.+)$')
        if ($m.Success) {
            $original = $m.Groups[1].Value.Trim()
            if ($original -match 'amtptp|apple|trackpad') { "  $published  <-  $original"; $found = $true }
            $published = ''
        }
    }
    if (-not $found) { '  none' }
}
Add-Cmd 'trackpad devices (all instances)' {
    $d = @(Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match '05AC|27A7|0001004C' -and $_.InstanceId -match '0265|0324|030E|2501|9601' })
    if ($d.Count -eq 0) { 'none - the trackpad is not connected / not enumerated' }
    foreach ($x in $d) { "  status=$($x.Status)  class=$($x.Class)  $($x.InstanceId)" }
}
Add-Cmd 'driver control device' {
    $src = @'
using System;
using System.Runtime.InteropServices;
public class MtCd {
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
  public static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFile(
      string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
}
'@
    try { if (-not ('MtCd' -as [type])) { Add-Type -TypeDefinition $src | Out-Null } } catch { 'Add-Type failed'; return }
    $access = [uint32]2147483648 -bor [uint32]1073741824
    $h = [MtCd]::CreateFile('\\.\AmtPtpControlDeviceUm', $access, [uint32]3, [IntPtr]::Zero, [uint32]3, [uint32]0, [IntPtr]::Zero)
    if ($h -and -not $h.IsInvalid) { $h.Dispose(); 'OPEN OK - the driver is bound and the control device exists' }
    else {
        $e = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        "OPEN FAILED - Win32 error $e  (2 = not bound/no device, 5 = not elevated)"
    }
}
Add-Cmd 'AmtPtpHidFilter service' {
    $s = Get-Service AmtPtpHidFilter -ErrorAction SilentlyContinue
    if ($s) { "$($s.Status)  $($s.StartType)" } else { 'not present' }
}

Add-Section 'third-party trackpad tools'
Add-Cmd 'processes / services / installed' {
    $hit = $false
    foreach ($n in @('MagicUtilities','Magic Utilities','Trackpad++','TrackpadPlusPlus','TPPService')) {
        if (Get-Process -Name $n -ErrorAction SilentlyContinue) { "process: $n"; $hit = $true }
        if (Get-Service -Name $n -ErrorAction SilentlyContinue) { "service: $n"; $hit = $true }
    }
    $apps = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match 'Magic Utilities|Trackpad\+\+|Magic Trackpad' } |
        Select-Object -ExpandProperty DisplayName -Unique
    foreach ($a in $apps) { "installed: $a"; $hit = $true }
    if (-not $hit) { 'none detected' }
}

Add-Section 'end of report'
Add-Line "Send this file if you need help: $OutFile"

$out | Set-Content -Path $OutFile -Encoding UTF8
Write-Host ''
Write-Host "Report written to:" -ForegroundColor Green
Write-Host "  $OutFile" -ForegroundColor Green
Write-Host ''
$out | ForEach-Object { Write-Host $_ }
