@echo off
rem ============================================================================
rem  Magic Trackpad for Windows - diagnostics
rem
rem  Double-click this file when something is wrong (panel does not show up, no
rem  tray icon, no battery, "Failed to open device. Error: 2"). It writes
rem  MagicTrackpad-diagnose.txt next to this script and shows it on screen.
rem  It changes nothing on the machine.
rem ============================================================================
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Diagnose.ps1" %*
echo.
echo  Press any key to close this window...
pause >nul
