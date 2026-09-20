@echo off
rem ============================================================================
rem  Magic Trackpad for Windows - one-click fix for
rem      "Failed to open device. Error: 2"
rem
rem  Double-click this file on the machine that shows that error. It does the
rem  complete repair in the right order (one UAC prompt, nothing to type):
rem
rem    1. removes every Apple / Magic Trackpad driver package and leftover
rem       device instance (including this project's SELF-SIGNED package, which
rem       only loads when Windows test signing is on),
rem    2. installs the MICROSOFT-SIGNED driver from driver-ms-signed\ - it needs
rem       neither test signing nor certificates, so it works on Windows 11 with
rem       Secure Boot enabled,
rem    3. restarts the trackpad device instances so Windows actually re-binds
rem       them (a device stuck in "Error" stays there otherwise),
rem    4. starts the control panel again.
rem
rem  The trackpad should come back without a reboot. If Bluetooth was paired
rem  before, you may have to remove + re-pair the trackpad once.
rem
rem  Full log: this window; the installer also writes nothing to disk by design.
rem ============================================================================
setlocal
set "SELF=%~f0"
set "ARGS=%*"

fltmc >nul 2>&1
if not errorlevel 1 goto :elevated

echo.
echo  Magic Trackpad - repairing "Failed to open device. Error: 2"
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
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Clean -SignedDriver %*
set "RC=%errorlevel%"

echo.
if "%RC%"=="0" (
    echo  Repair finished. Check the control panel:
    echo    - if it still says "Failed to open device. Error: 2", remove the
    echo      trackpad in Bluetooth settings and pair it again, then run
    echo      Diagnose.cmd and send MagicTrackpad-diagnose.txt
) else (
    echo  Repair FAILED ^(exit code %RC%^) - see the messages above.
)
echo.
echo  Press any key to close this window...
pause >nul
exit /b %RC%
