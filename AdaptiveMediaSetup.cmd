@echo off
setlocal EnableExtensions
set "ROOT=%~dp0"
set "PAYLOAD=%ROOT%payload"
set "APP=%PAYLOAD%\AdaptiveMedia.ps1"

if not exist "%ROOT%Install-AdaptiveMedia.ps1" goto :incomplete
for %%P in (00 01 02 03 04 05 06) do if not exist "%PAYLOAD%\AdaptiveMedia.ps1.part%%P" goto :incomplete

echo Preparing Adaptive Media launcher...
del /q "%APP%" >nul 2>&1
copy /b "%PAYLOAD%\AdaptiveMedia.ps1.part00"+"%PAYLOAD%\AdaptiveMedia.ps1.part01"+"%PAYLOAD%\AdaptiveMedia.ps1.part02"+"%PAYLOAD%\AdaptiveMedia.ps1.part03"+"%PAYLOAD%\AdaptiveMedia.ps1.part04"+"%PAYLOAD%\AdaptiveMedia.ps1.part05"+"%PAYLOAD%\AdaptiveMedia.ps1.part06" "%APP%" >nul
if errorlevel 1 goto :badbuild

set "HASH="
for /f %%H in ('powershell.exe -NoLogo -NoProfile -Command "(Get-FileHash -Algorithm SHA256 -LiteralPath '%APP%').Hash.ToLowerInvariant()"') do set "HASH=%%H"
if /I not "%HASH%"=="ebf267afbb19866fc7040ce687ee43b013378706fe47f7040e9a78e36f4c2d02" goto :badhash

start "" powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%ROOT%Install-AdaptiveMedia.ps1"
exit /b 0

:incomplete
echo.
echo Adaptive Media download is incomplete. Extract the entire GitHub ZIP first.
pause
exit /b 2

:badbuild
echo.
echo Adaptive Media launcher could not be reconstructed.
pause
exit /b 3

:badhash
echo.
echo SECURITY CHECK FAILED: reconstructed launcher hash does not match the published build.
echo Nothing was installed. Download a fresh copy from the official GitHub branch.
pause
exit /b 4
