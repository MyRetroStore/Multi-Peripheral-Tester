@echo off
setlocal
cd /d "%~dp0"
rem Double-click wrapper: checks PowerShell, runs the updater, keeps the window open.
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" (
  echo.
  echo Windows PowerShell was not found on this PC.
  echo.
  pause
  exit /b 1
)
set "PSMAJOR=0"
"%PS%" -NoProfile -Command "$PSVersionTable.PSVersion.Major" > "%TEMP%\mpt_psver.txt" 2>nul
if exist "%TEMP%\mpt_psver.txt" set /p PSMAJOR=<"%TEMP%\mpt_psver.txt"
del "%TEMP%\mpt_psver.txt" >nul 2>nul
if not defined PSMAJOR set "PSMAJOR=0"
if %PSMAJOR% LSS 3 (
  echo.
  echo This PC has Windows PowerShell %PSMAJOR%.  The updater needs 3.0 or newer,
  echo because GitHub now requires TLS 1.2, which PowerShell 2.0 cannot do.
  echo.
  echo   Option 1 - update this PC: install Windows Management Framework 5.1
  echo              https://www.microsoft.com/download/details.aspx?id=54616
  echo              reboot, then run this again.
  echo.
  echo   Option 2 - flash by hand: download the .hex from
  echo              https://github.com/MyRetroStore/Multi-Peripheral-Tester/releases/latest
  echo              then, with avrdude installed and the board on COM3:
  echo              avrdude -c arduino -p m1280 -P COM3 -b 57600 -D -U flash:w:firmware.hex:i
  echo.
  pause
  exit /b 1
)
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0updater.ps1" %*
echo.
pause
