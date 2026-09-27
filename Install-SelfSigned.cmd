@echo off
rem ============================================================================
rem  Magic Trackpad for Windows - one-click installer, SELF-SIGNED driver
rem
rem  Same as Install.cmd, but it always installs the driver from
rem  driver-self-signed\ (rotation + force click) and trusts the certificates in
rem  certs\ - no switch to remember, no commands to type.
rem
rem  Double-click this file and confirm the one Windows UAC prompt.
rem
rem  The self-signed driver is self-signed BY DESIGN: Windows only loads it with
rem  test signing ON (or with Secure Boot OFF and our certificate trusted, which
rem  this script does for you). If the trackpad does not come up, run
rem
rem      bcdedit /set testsigning on
rem
rem  then reboot. Secure Boot has to be off for that.
rem
rem  Optional arguments are passed through to install.ps1, e.g.
rem      Install-SelfSigned.cmd -Autostart -StartMinimized
rem      Install-SelfSigned.cmd -DriverOnly
rem ============================================================================
setlocal
set "SELF=%~f0"
set "ARGS=%*"

if not exist "%~dp0driver-self-signed\AmtPtpDevice.inf" (
    echo.
    echo  This folder has no driver-self-signed\ package.
    echo  Use Install.cmd for the Microsoft-signed driver, or download the
    echo  "...(self-signed)" archive from the releases page.
    echo.
    pause
    exit /b 2
)

reg query "HKLM\SYSTEM\CurrentControlSet\Control" /v SystemStartOptions 2>nul | findstr /i TESTSIGNING >nul
if errorlevel 1 (
    echo  test signing: OFF  - the self-signed driver will not load yet.
    echo                  Turn it on with:  bcdedit /set testsigning on   ^(then reboot^)
) else (
    echo  test signing: ON
)
reg query "HKLM\SYSTEM\CurrentControlSet\Control\SecureBoot\State" /v UEFISecureBootEnabled 2>nul | findstr /i "0x1" >nul
if not errorlevel 1 echo  Secure Boot:  ON   - this BLOCKS self-signed drivers; turn it off in the UEFI setup.
echo.

rem --- already elevated? (fltmc only runs for administrators) -----------------
fltmc >nul 2>&1
if not errorlevel 1 goto :elevated

echo  Magic Trackpad - self-signed installer
echo  Requesting administrator rights (please confirm the Windows prompt)...
echo.

if defined ARGS (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%SELF%' -ArgumentList '-SelfSigned','%ARGS%' -Verb RunAs"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%SELF%' -ArgumentList '-SelfSigned' -Verb RunAs"
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
rem the UAC relaunch already passes -SelfSigned; do not add it twice
set "SS=-SelfSigned"
echo %* | findstr /i /c:"-SelfSigned" >nul
if not errorlevel 1 set "SS="
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %SS% %*
set "RC=%errorlevel%"

echo.
if "%RC%"=="0" (
    echo  Self-signed install finished successfully.
    echo  If the trackpad does not react, check test signing ^(bcdedit^) and reboot.
) else (
    echo  Install FAILED ^(exit code %RC%^) - see the messages above.
)
echo.
echo  Press any key to close this window...
pause >nul
exit /b %RC%
