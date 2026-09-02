@echo off
setlocal
set "SCRIPT=%~dp0Test-0.3.2-Hardware.ps1"

if not exist "%SCRIPT%" (
  echo Adaptive Media hardware certification script is missing.
  pause
  exit /b 2
)

echo Adaptive Media 0.3.2 Hardware Certification
echo -------------------------------------------
echo This is an objective runtime gate. It does not ask for picture-quality judgement.
echo.

if "%~1"=="" (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
) else (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -MediaPath "%~1"
)
set "CODE=%ERRORLEVEL%"

echo.
if "%CODE%"=="0" echo RESULT: PASS
if "%CODE%"=="2" echo RESULT: FAIL
if "%CODE%"=="3" echo RESULT: UNVERIFIED
if not "%CODE%"=="0" if not "%CODE%"=="2" if not "%CODE%"=="3" echo RESULT: ERROR ^(exit code %CODE%^)
echo Report: %%LOCALAPPDATA%%\AdaptiveMedia\certification\0.3.2-hardware.json
echo.
pause
exit /b %CODE%
