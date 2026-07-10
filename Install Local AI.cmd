@echo off
title Local AI - installer
echo.
echo   Local AI - guided installer
echo   ---------------------------
echo   This checks your PC, picks AI models that fit your graphics card,
echo   and sets up a private local chat (like ChatGPT, but on your own PC).
echo   Nothing leaves your computer unless you turn that on yourself.
echo.
echo   Windows may show a blue "Windows protected your PC" or a yellow
echo   "Open File - Security Warning" box - that is normal for a downloaded
echo   file. Click "More info" then "Run anyway", or "Run".
echo.
pause

rem If this .cmd sits inside the downloaded repo, run the local bootstrap.
rem Otherwise (someone downloaded just this one file), fetch it from master.
set "BOOT=%~dp0installer\bootstrap.ps1"
if exist "%BOOT%" goto :run

echo   Downloading the installer...
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/allusionsafk/localai-windows-starter/master/installer/bootstrap.ps1' -OutFile ($env:TEMP + '\localai-bootstrap.ps1')"
if errorlevel 1 goto :failed
set "BOOT=%TEMP%\localai-bootstrap.ps1"

:run
echo   Starting the installer...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%BOOT%" %*
if errorlevel 1 goto :failed
echo.
echo   Finished. Scroll up for your chat and search web addresses.
goto :done

:failed
echo.
echo   Something went wrong - read the messages above this line.
echo   You can re-run this file to try again.

:done
echo.
pause
