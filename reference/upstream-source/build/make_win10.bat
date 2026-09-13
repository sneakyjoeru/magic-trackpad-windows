@echo off
setlocal

set /p "inf2catPath=Please enter the full path to the inf2cat.exe file (defaults to C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x86\inf2cat.exe): "
if "%inf2catPath%"=="" set "inf2catPath=C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x86\inf2cat.exe"
if not exist "%inf2catPath%" exit /b 1

set /p "sha1TpDr=Please enter the SHA1 Thumbprint for signing the driver package: "

rmdir result /S /Q
mkdir result
mkdir result\AMD64
copy AmtPtpDevice_AMD64.inf result\AMD64\AmtPtpDevice.inf
copy .\MT2FW11-20260223-MSSigned\AmtPtpControlPanel.exe result
copy .\drivers\MagicTrackpad2ForWindows.cer result
copy .\MT2FW11-20260223-MSSigned\AMD64\AmtPtpDeviceUsbUm.dll result\AMD64
copy .\MT2FW11-20260223-MSSigned\AMD64\AmtPtpHidFilter.sys result\AMD64

"%inf2catPath%" /driver:result\AMD64 /os:10_X64
if %errorlevel% neq 0 exit /b %errorlevel%

signtool sign /v /fd sha256 /sha1 "%sha1TpDr%" /t http://timestamp.digicert.com result\AMD64\AmtPtpDevice.cat
if %errorlevel% neq 0 exit /b %errorlevel%

echo ---------
echo Success!
echo ---------
exit /b 0

endlocal
