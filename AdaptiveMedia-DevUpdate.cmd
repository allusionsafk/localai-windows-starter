@echo off
setlocal EnableExtensions
set "WORK=%LOCALAPPDATA%\AdaptiveMediaDev"
set "ZIP=%TEMP%\AdaptiveMedia-DevKit.zip"
set "B64=%TEMP%\AdaptiveMedia-DevKit.b64"
set "MANIFEST=%TEMP%\AdaptiveMedia-manifest.json"
set "EXTRACT=%TEMP%\AdaptiveMedia-DevKit-extract"
set "LOG=%WORK%\last-build.log"
set "BASE=https://raw.githubusercontent.com/allusionsafk/localai-windows-starter/adaptive-media-dev"

if not exist "%WORK%" mkdir "%WORK%"
echo ============================================================
echo  Adaptive Media - one-click development update
echo ============================================================
echo.
echo Downloading, verifying, building and smoke-testing the current dev build...
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue';" ^
  "$base='%BASE%'; $zip='%ZIP%'; $b64='%B64%'; $manifestPath='%MANIFEST%'; $extract='%EXTRACT%'; $work='%WORK%';" ^
  "Invoke-WebRequest -UseBasicParsing -Uri ($base + '/manifest.json') -OutFile $manifestPath; $m=Get-Content $manifestPath -Raw | ConvertFrom-Json;" ^
  "Invoke-WebRequest -UseBasicParsing -Uri ($base + '/AdaptiveMedia-DevKit.b64') -OutFile $b64; $text=(Get-Content $b64 -Raw).Trim(); [IO.File]::WriteAllBytes($zip,[Convert]::FromBase64String($text));" ^
  "$actual=(Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant(); if($actual -ne ([string]$m.sha256).ToLowerInvariant()){throw 'DevKit SHA-256 verification failed.'};" ^
  "Remove-Item -Recurse -Force $extract -ErrorAction SilentlyContinue; Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force; $root=Get-ChildItem $extract -Directory | Select-Object -First 1; if(-not $root){throw 'DevKit archive was empty.'};" ^
  "$src=Join-Path $work 'source'; Remove-Item -Recurse -Force $src -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $src|Out-Null; Copy-Item -Path (Join-Path $root.FullName '*') -Destination $src -Recurse -Force; Set-Location $src;" ^
  "& '.\scripts\Build-Dev.ps1' -InstallTools -Clean -SmokeTest *>&1 | Tee-Object -FilePath '%LOG%'; if($LASTEXITCODE -ne 0){throw 'Build failed. See %LOG%'};" ^
  "$setup=Get-ChildItem '.\dist' -Filter 'AdaptiveMediaSetup-*.exe' | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if(-not $setup){throw 'Installer not found.'}; Start-Process $setup.FullName"

if errorlevel 1 goto :fail
echo.
echo Build complete. The installer should now be open.
echo Keep this file: future dev updates are the same double-click.
timeout /t 5 >nul
exit /b 0

:fail
echo.
echo Update/build failed. Log: %LOG%
echo.
pause
exit /b 1
