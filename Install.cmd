@echo off
rem ============================================================================
rem  Magic Trackpad for Windows - one-click installer
rem
rem  Double-click this file (or the "Install Magic Trackpad" shortcut next to
rem  it). It asks Windows for administrator rights once - that UAC prompt is
rem  the only thing you have to click - then it installs the driver, the
rem  certificates and the tray control panel. No commands to type.
rem
rem  Optional arguments are passed straight through to install.ps1, e.g.
rem      Install.cmd -Autostart -StartMinimized
rem      Install.cmd -DriverOnly
rem      Install.cmd -SkipLaunch
rem ============================================================================
setlocal
set "SELF=%~f0"
set "ARGS=%*"

rem --- already elevated? (fltmc only runs for administrators) -----------------
fltmc >nul 2>&1
if not errorlevel 1 goto :elevated

echo.
echo  Magic Trackpad - installer
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
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
set "RC=%errorlevel%"

echo.
if "%RC%"=="0" (
    echo  Install finished successfully.
) else (
    echo  Install FAILED ^(exit code %RC%^) - see the messages above.
)
echo.
echo  Press any key to close this window...
pause >nul
exit /b %RC%
