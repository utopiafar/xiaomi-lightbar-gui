@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-windows-shortcut.ps1"
if errorlevel 1 (
  echo Failed to create the Start menu shortcut.
  pause
  exit /b 1
)
echo You can now find Xiaomi Lightbar in the Start menu.
pause
