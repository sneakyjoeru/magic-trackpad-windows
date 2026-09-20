@echo off
rem ============================================================================
rem  Magic Trackpad for Windows - remove ALL known Apple / Magic Trackpad drivers
rem
rem  Double-click this file on a machine where the panel reports
rem      "Failed to open device. Error: 2"
rem  or where an older Apple / MagicTrackpad2ForWindows driver is in the way.
rem  It removes every Apple trackpad driver package and the leftover device
rem  instances, then re-scans - after that run Install.cmd again.
rem
rem  Options (pass them on the command line if you want):
rem      Uninstall-All-Apple-Drivers.cmd -DryRun          list only, change nothing
rem      Uninstall-All-Apple-Drivers.cmd -IncludeCerts    also untrust our certificates
rem ============================================================================
setlocal
set "SELF=%~f0"
set "ARGS=%*"

fltmc >nul 2>&1
if not errorlevel 1 goto :elevated

echo.
echo  Magic Trackpad - clean up all Apple trackpad drivers
echo  Requesting administrator rights (please confirm the Windows prompt)...
echo.

if defined ARGS (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%SELF%' -ArgumentList '%ARGS%' -Verb RunAs"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%SELF%' -Verb RunAs"
)
if errorlevel 1 (
    echo.
    echo  Elevation was cancelled - nothing was changed.
    echo.
    pause
)
exit /b

:elevated
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall-All-Apple-Drivers.ps1" %*
set "RC=%errorlevel%"

echo.
if "%RC%"=="0" (
    echo  Cleanup finished.
) else (
    echo  Cleanup finished with exit code %RC% - see the messages above.
)
echo.
echo  Press any key to close this window...
pause >nul
exit /b %RC%
