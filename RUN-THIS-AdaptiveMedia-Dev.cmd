@echo off
setlocal EnableExtensions
title Adaptive Media Dev - RUN THIS

set "REMOTE_BASE=https://raw.githubusercontent.com/allusionsafk/localai-windows-starter/adaptive-media-dev/AdaptiveMedia-DevUpdate.ps1"
set "LOCAL=%TEMP%\AdaptiveMedia-DevUpdate-LATEST.ps1"

echo ============================================================
echo  Adaptive Media Development - RUN THIS FILE
echo ============================================================
echo.
echo This is the permanent bootstrap.
echo It ignores old local updater copies and fetches the current updater.
echo.

for /f "usebackq delims=" %%T in (`powershell.exe -NoLogo -NoProfile -Command "[DateTime]::UtcNow.Ticks"`) do set "CACHEBUST=%%T"

del /q "%LOCAL%" >nul 2>&1

echo Fetching current updater from GitHub...
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; Invoke-WebRequest -UseBasicParsing -Headers @{'Cache-Control'='no-cache'} -Uri ('%REMOTE_BASE%?cb=%CACHEBUST%') -OutFile '%LOCAL%'"
if errorlevel 1 goto :downloadfail

echo Verifying updater generation...
findstr /c:"StartupObject>AdaptiveMedia.Program" "%LOCAL%" >nul || goto :stale
findstr /c:"App.xaml already generates the AdaptiveMedia.App type" "%LOCAL%" >nul || goto :stale
findstr /c:"v0.3.0-dev6" "%LOCAL%" >nul || goto :stale

echo Updater generation check: PASS
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%LOCAL%"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" goto :failed
exit /b 0

:stale
echo.
echo ERROR: GitHub returned an updater that did not contain the required dev6 markers.
echo Nothing was built. Try this file again in a minute.
pause
exit /b 3

:downloadfail
echo.
echo ERROR: Could not download the current updater.
echo Check the internet connection and try again.
pause
exit /b 2

:failed
echo.
echo The current updater reported a failure.
echo Upload:
echo   %%LOCALAPPDATA%%\AdaptiveMediaDev\last-build.log
pause
exit /b %RC%
