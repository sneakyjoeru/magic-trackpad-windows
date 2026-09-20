@echo off
rem ============================================================================
rem  Magic Trackpad for Windows - restore normal driver signature enforcement
rem
rem  Turns Windows test signing back OFF (only needed for the self-signed driver
rem  variant used by VID 27A7 clones). REBOOT afterwards. Secure Boot itself can
rem  only be re-enabled in the UEFI/BIOS setup.
rem
rem  Double-click; use "Restore-Signature-Enforcement.cmd -DryRun" to just look.
rem ============================================================================
setlocal
set "SELF=%~f0"
set "ARGS=%*"

fltmc >nul 2>&1
if not errorlevel 1 goto :elevated

echo.
echo  Magic Trackpad - restoring driver signature enforcement
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
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Restore-Signature-Enforcement.ps1" %*
echo.
echo  Press any key to close this window...
pause >nul
