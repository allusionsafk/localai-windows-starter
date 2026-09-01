#requires -Version 5.1
$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms

$installDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$desktop = [Environment]::GetFolderPath('Desktop')
$start = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs\Adaptive Media'

$answer = [System.Windows.Forms.MessageBox]::Show(
    "Remove Adaptive Media, its isolated MPV configuration, shortcuts, context-menu entries and local settings?`r`n`r`nShared components such as MPV, yt-dlp and MPC-BE will be left installed so uninstalling Adaptive Media cannot remove software you may use elsewhere.",
    'Uninstall Adaptive Media',
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Question)
if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { exit 0 }

Remove-Item -LiteralPath (Join-Path $desktop 'Adaptive Media.lnk') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $start -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath 'HKCU:\Software\Classes\SystemFileAssociations\video\shell\AdaptiveMedia' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath 'HKCU:\Software\Classes\Directory\shell\AdaptiveMedia' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AdaptiveMedia' -Recurse -Force -ErrorAction SilentlyContinue

# Defer deletion of the directory because this script lives inside it.
$cmd = Join-Path $env:TEMP ('adaptive-media-remove-' + [guid]::NewGuid().ToString('N') + '.cmd')
$content = @"
@echo off
ping 127.0.0.1 -n 3 >nul
rmdir /s /q "$installDir"
del /q "%~f0"
"@
$content | Set-Content -LiteralPath $cmd -Encoding ASCII
Start-Process -FilePath $cmd -WindowStyle Hidden | Out-Null

[void][System.Windows.Forms.MessageBox]::Show('Adaptive Media has been removed. Shared media components were left installed.', 'Adaptive Media', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
