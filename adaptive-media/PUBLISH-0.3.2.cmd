@echo off
setlocal EnableExtensions
title Adaptive Media 0.3.2 - Publish Certified Release

echo ============================================================
echo  Adaptive Media 0.3.2 - Publish exact certified installer
echo ============================================================
echo.
echo This does not rebuild Adaptive Media and does not modify v0.3.1.
echo It verifies the certified SHA-256 before upload, verifies the
echo draft asset on GitHub, publishes it, downloads it again, and
echo verifies the public SHA-256 one final time.
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Publish-0.3.2-Locally.ps1"
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" (
  echo Publication finished successfully.
) else (
  echo Publication did NOT complete. See the error above.
)
echo.
pause
exit /b %RC%
