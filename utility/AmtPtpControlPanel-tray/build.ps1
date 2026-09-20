# Builds AmtPtpControlPanel.exe with the .NET 4.0 C# compiler (no project file needed).
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$csc = Join-Path $env:Windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$out = Join-Path $here 'AmtPtpControlPanel.exe'
$src = @('Main.cs','Main.Designer.cs','Tray.cs','Program.cs') | ForEach-Object { Join-Path $here $_ }
$src += Join-Path $here 'Properties\AssemblyInfo.cs'
Push-Location $here
try {
    & $csc /nologo /target:winexe /optimize+ "/out:$out" `
        /r:System.dll /r:System.Core.dll /r:System.Data.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll `
        "/resource:$here\Icon1.ico",AmtPtpControlPanel.Icon1.ico `
        "/win32icon:$here\Icon1.ico" `
        $src
    if ($LASTEXITCODE -eq 0 -and (Test-Path $out)) {
        Write-Host "Built $out"
    } else {
        Write-Host "Build failed (exit $LASTEXITCODE)" -ForegroundColor Red
        exit 1
    }
} finally { Pop-Location }
