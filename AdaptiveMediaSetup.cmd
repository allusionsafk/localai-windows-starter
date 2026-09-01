@echo off
setlocal
if not exist "%~dp0Install-AdaptiveMedia.ps1" (
  echo Installer payload is incomplete. Extract the whole ZIP first.
  pause
  exit /b 2
)
start "" powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Install-AdaptiveMedia.ps1"
exit /b 0
