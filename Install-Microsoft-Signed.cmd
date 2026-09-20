@echo off
rem ============================================================================
rem  Magic Trackpad for Windows - install the MICROSOFT-SIGNED driver
rem
rem  Use this on a machine where the normal install leaves the panel saying
rem  "Failed to open device. Error: 2", or where the self-signed driver cannot
rem  load because test signing is off (Secure Boot on / Windows 11):
rem
rem      the self-signed kernel filter (AmtPtpHidFilter.sys) NEEDS test signing,
rem      the Microsoft-signed package in driver-ms-signed\ does not.
rem
rem  Double-click this file and confirm the UAC prompt. Nothing else to type.
rem  Add -Clean on the command line to remove every old Apple/trackpad driver
rem  first (recommended when a self-signed package is already installed, so the
rem  two cannot compete):
rem
rem      Install-Microsoft-Signed.cmd -Clean
rem ============================================================================
setlocal
set "SELF=%~f0"
set "ARGS=%*"

fltmc >nul 2>&1
if not errorlevel 1 goto :elevated

echo.
echo  Magic Trackpad - installing the Microsoft-signed driver
echo  Requesting administrator rights (please confirm the Windows prompt)...
echo.

if defined ARGS (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%SELF%' -ArgumentList '%ARGS%' -Verb RunAs"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%SELF%' -Verb RunAs"
)
if errorlevel 1 (
    echo.
    echo  Elevation was cancelled - nothing was installed.
    echo.
    pause
)
exit /b

:elevated
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -SignedDriver %*
set "RC=%errorlevel%"

echo.
if "%RC%"=="0" (
    echo  Microsoft-signed driver installed.
    echo  If the trackpad was in an error state, unplug/replug it ^(or remove and
    echo  re-pair Bluetooth^) once so Windows re-enumerates it.
) else (
    echo  Install FAILED ^(exit code %RC%^) - see the messages above.
)
echo.
echo  Press any key to close this window...
pause >nul
exit /b %RC%
