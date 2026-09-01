@echo off
title AFK AI - installer
echo.
echo   AFK AI - guided installer
echo   -------------------------
echo   This checks your PC, picks AI models that fit your graphics card,
echo   and sets up a local-first AI chat on your own PC.
echo   Model inference can stay local. Setup, model downloads, and features
echo   such as web search can use the internet when needed or enabled.
echo.
echo   If an earlier try failed, no cleanup needed - the installer moves the
echo   old folder aside by itself and starts fresh.
echo.

rem If this .cmd sits inside the downloaded repo, run the local bootstrap.
rem Otherwise (someone downloaded just this one file), fetch an immutable
rem bootstrap commit and verify its SHA-256 before PowerShell is allowed to run it.
set "BOOT=%~dp0installer\bootstrap.ps1"
if exist "%BOOT%" goto :run

set "BOOTSTRAP_COMMIT=dbd8107872af037a328464c078fdc10e50d032cc"
set "BOOTSTRAP_SHA256=440B3308BC11A3CA96432170A026B20AC7BA5A087C62B36112A4659CF3F619EF"
set "BOOT=%TEMP%\localai-bootstrap-%BOOTSTRAP_COMMIT%.ps1"
set "BOOT_URL=https://raw.githubusercontent.com/allusionsafk/localai-windows-starter/%BOOTSTRAP_COMMIT%/installer/bootstrap.ps1"

echo   Downloading the installer...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; $out=$env:BOOT; Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue; Invoke-WebRequest -UseBasicParsing $env:BOOT_URL -OutFile $out; $actual=(Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash.ToUpperInvariant(); $expected=$env:BOOTSTRAP_SHA256.ToUpperInvariant(); if ($actual -ne $expected) { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue; Write-Error ('Installer integrity check failed. Expected SHA-256 ' + $expected + ', got ' + $actual + '. Refusing to run the downloaded bootstrap.'); exit 23 }"
if errorlevel 1 goto :failed
if not exist "%BOOT%" goto :failed

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
echo   Something went wrong - read the messages above this line.
echo   Double-click this file again to retry; it continues where it left
echo   off and moves any broken old folder aside automatically.

:done
echo.
pause
