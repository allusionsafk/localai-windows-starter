@echo off
title Local AI - installer
echo.
echo   Local AI - guided installer
echo   ---------------------------
echo   This checks your PC, picks AI models that fit your graphics card,
echo   and sets up a private local chat (like ChatGPT, but on your own PC).
echo   Nothing leaves your computer unless you turn that on yourself.
echo.
echo   If an earlier try failed, no cleanup needed - the installer moves the
echo   old folder aside by itself and starts fresh.
echo.

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
rem Exit 10 = the planned Docker Desktop checkpoint, not a failure.
if errorlevel 11 goto :failed
if errorlevel 10 goto :dockerwait
if errorlevel 1 goto :failed
echo.
echo   Finished. Your chat is at http://127.0.0.1:3000 (see the summary above).
goto :done

:dockerwait
echo.
echo   Almost there - one more double-click:
echo   1. Open Docker Desktop (just installed; find it in the Start menu).
echo   2. Accept its terms and let it finish setting up.
echo      If it asks to restart Windows, restart.
echo   3. Double-click this file again. It continues where it left off.
goto :done

:failed
echo.
echo   AFK-200 - Setup stopped before it finished.
echo.
echo   What to do first: double-click this file again. Setup continues from
echo   where it stopped, and moves a broken old folder aside by itself. Most
echo   problems clear on the second try.
echo.
echo   If it stops again, the most common causes are:
echo     AFK-201  No internet, or a company/school network blocking downloads.
echo              Check you can open a web page, then try again.
echo     AFK-203  Docker Desktop is installed but has not finished setup.
echo              Open Docker Desktop once, finish its setup, then retry.
echo     AFK-204  Windows needs restarting to finish installing something.
echo              Restart the PC, then double-click this file again.
echo     AFK-205  Not enough free disk space. Free up about 40 GB, then retry.
echo.
echo   Still stuck? Double-click "AFK AI Control Center.cmd" in this folder
echo   and use Copy Diagnostic Report, then send that text to whoever set
echo   this up. It contains no chats, passwords or personal files.
echo.
echo   Advanced: the raw technical detail is in the messages above this box.

:done
echo.
pause
