@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-universal.ps1" -Root "%~dp0."
if errorlevel 1 (
  echo.
  echo pFlow was not installed. Read the message above.
  pause
  exit /b 1
)
echo.
echo Open pFlow by Pesh from the Start menu. Its icon appears in the tray.
pause
