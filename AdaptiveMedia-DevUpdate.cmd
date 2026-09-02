@echo off
setlocal EnableExtensions
set "WORK=%LOCALAPPDATA%\AdaptiveMediaDev"
set "ZIP=%TEMP%\AdaptiveMedia-DevKit.zip"
set "B64=%TEMP%\AdaptiveMedia-DevKit.b64"
set "MANIFEST=%TEMP%\AdaptiveMedia-manifest.json"
set "EXTRACT=%TEMP%\AdaptiveMedia-DevKit-extract"
set "SRC=%WORK%\source"
set "LOG=%WORK%\last-build.log"
set "BASE=https://raw.githubusercontent.com/allusionsafk/localai-windows-starter/adaptive-media-dev"

if not exist "%WORK%" mkdir "%WORK%"
echo ============================================================
echo  Adaptive Media - one-click development update
echo ============================================================
echo.
echo Downloading, verifying, building and smoke-testing the current dev build...
echo.

rem Download, verify and stage source. Keep this command focused on file operations;
rem build output redirection happens at the CMD layer below to avoid nested & parsing.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue';" ^
  "$base='%BASE%'; $zip='%ZIP%'; $b64='%B64%'; $manifestPath='%MANIFEST%'; $extract='%EXTRACT%'; $src='%SRC%';" ^
  "Invoke-WebRequest -UseBasicParsing -Uri ($base + '/manifest.json') -OutFile $manifestPath; $m=Get-Content $manifestPath -Raw | ConvertFrom-Json;" ^
  "Invoke-WebRequest -UseBasicParsing -Uri ($base + '/AdaptiveMedia-DevKit.b64') -OutFile $b64; $text=(Get-Content $b64 -Raw).Trim(); [IO.File]::WriteAllBytes($zip,[Convert]::FromBase64String($text));" ^
  "$actual=(Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant(); if($actual -ne ([string]$m.sha256).ToLowerInvariant()){throw 'DevKit SHA-256 verification failed.'};" ^
  "Remove-Item -Recurse -Force $extract -ErrorAction SilentlyContinue; Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force; $root=Get-ChildItem $extract -Directory | Select-Object -First 1; if(-not $root){throw 'DevKit archive was empty.'};" ^
  "Remove-Item -Recurse -Force $src -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $src|Out-Null; Copy-Item -Path (Join-Path $root.FullName '*') -Destination $src -Recurse -Force"
if errorlevel 1 goto :fail

rem Repair namespace imports required by the first WPF Windows compile.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop'; $root='%SRC%\src\AdaptiveMedia.App';" ^
  "$map=@{'App.xaml.cs'=@('using System;','using System.IO;','using System.Linq;');'BackendBridge.cs'=@('using System;','using System.Collections.Generic;','using System.IO;','using System.Threading.Tasks;');'MainWindow.xaml.cs'=@('using System;','using System.Collections.Generic;','using System.Linq;','using System.Threading.Tasks;');'SettingsStore.cs'=@('using System;','using System.IO;');'UrlDialog.xaml.cs'=@('using System;')};" ^
  "foreach($name in $map.Keys){$path=Join-Path $root $name; if(Test-Path $path){$t=[IO.File]::ReadAllText($path); $prefix=''; foreach($u in $map[$name]){if($t -notmatch [regex]::Escape($u)){$prefix += $u + [Environment]::NewLine}}; if($prefix){[IO.File]::WriteAllText($path,$prefix+$t,[Text.UTF8Encoding]::new($false))}}}"
if errorlevel 1 goto :fail

echo Building WPF app and installer...
echo.
del /q "%LOG%" >nul 2>&1
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SRC%\scripts\Build-Dev.ps1" -InstallTools -Clean -SmokeTest > "%LOG%" 2>&1
set "BUILD_RC=%ERRORLEVEL%"
type "%LOG%"
echo.
if not "%BUILD_RC%"=="0" goto :buildfail

for /f "usebackq delims=" %%I in (`powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$s=Get-ChildItem -LiteralPath '%SRC%\dist' -Filter 'AdaptiveMediaSetup-*.exe' -File ^| Sort-Object LastWriteTime -Descending ^| Select-Object -First 1; if($s){$s.FullName}"`) do set "SETUP=%%I"
if not defined SETUP goto :noinstaller
if not exist "%SETUP%" goto :noinstaller

echo.
echo Build complete. Opening installer...
start "" "%SETUP%"
echo Keep this file: future dev updates are the same double-click.
timeout /t 5 >nul
exit /b 0

:buildfail
echo.
echo Build failed with exit code %BUILD_RC%.
echo Log: %LOG%
pause
exit /b %BUILD_RC%

:noinstaller
echo.
echo Build reported success, but the installer EXE was not found.
echo Log: %LOG%
pause
exit /b 3

:fail
echo.
echo Update/build preparation failed. Log: %LOG%
echo.
pause
exit /b 1
