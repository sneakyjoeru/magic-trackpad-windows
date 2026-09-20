@echo off
rem ============================================================================
rem  Magic Trackpad for Windows - one-click uninstaller
rem
rem  Removes the tray control panel, the autostart entry, the imported driver
rem  package and the trusted certificates (one UAC prompt).
rem ============================================================================
setlocal
set "SELF=%~f0"
set "ARGS=%*"

fltmc >nul 2>&1
if not errorlevel 1 goto :elevated

echo.
echo  Magic Trackpad - uninstall
echo  Requesting administrator rights (please confirm the Windows prompt)...
echo.

if defined ARGS (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%SELF%' -ArgumentList '%ARGS%' -Verb RunAs"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%SELF%' -Verb RunAs"
)
if errorlevel 1 (
    echo.
    echo  Elevation was cancelled - nothing was removed.
    echo.
    pause
)
exit /b

:elevated
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Uninstall %*
set "RC=%errorlevel%"

echo.
if "%RC%"=="0" (
    echo  Uninstall finished.
) else (
    echo  Uninstall finished with exit code %RC% - see the messages above.
)
echo.
echo  Press any key to close this window...
pause >nul
exit /b %RC%
