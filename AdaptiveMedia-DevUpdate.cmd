@echo off
setlocal EnableExtensions
title Adaptive Media Dev Update
set "REMOTE=https://raw.githubusercontent.com/allusionsafk/localai-windows-starter/adaptive-media-dev/AdaptiveMedia-DevUpdate.ps1"
set "LOCAL=%TEMP%\AdaptiveMedia-DevUpdate.ps1"

echo ============================================================
echo  Adaptive Media - permanent development updater
echo ============================================================
echo.
echo Fetching the latest updater logic...
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; Invoke-WebRequest -UseBasicParsing -Uri '%REMOTE%' -OutFile '%LOCAL%'"
if errorlevel 1 goto :downloadfail

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%LOCAL%"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" goto :failed
exit /b 0

:downloadfail
echo.
echo Could not download the current updater.
echo Check your internet connection and try again.
pause
exit /b 2

:failed
echo.
echo The updater reported a failure.
pause
exit /b %RC%
