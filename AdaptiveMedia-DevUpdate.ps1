# Adaptive Media permanent development updater
# This file is fetched fresh by AdaptiveMedia-Dev.cmd on every run.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$RepoBase = 'https://raw.githubusercontent.com/allusionsafk/localai-windows-starter/adaptive-media-dev'
$Work = Join-Path $env:LOCALAPPDATA 'AdaptiveMediaDev'
$Source = Join-Path $Work 'source'
$Log = Join-Path $Work 'last-build.log'
$TempRoot = Join-Path $env:TEMP 'AdaptiveMediaDevUpdate'
$Zip = Join-Path $TempRoot 'AdaptiveMedia-DevKit.zip'
$B64 = Join-Path $TempRoot 'AdaptiveMedia-DevKit.b64'
$ManifestPath = Join-Path $TempRoot 'manifest.json'
$Extract = Join-Path $TempRoot 'extract'

function Banner([string]$Text) {
    Write-Host ''
    Write-Host ('=' * 64) -ForegroundColor Cyan
    Write-Host (' ' + $Text) -ForegroundColor Cyan
    Write-Host ('=' * 64) -ForegroundColor Cyan
    Write-Host ''
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Ensure-Using([string]$Path, [string[]]$Usings) {
    if (-not (Test-Path $Path)) { return }
    $text = [IO.File]::ReadAllText($Path)
    $prefix = ''
    foreach ($u in $Usings) {
        if ($text -notmatch [regex]::Escape($u)) {
            $prefix += $u + [Environment]::NewLine
        }
    }
    if ($prefix) { Write-Utf8NoBom $Path ($prefix + $text) }
}

function Apply-CurrentMigrations {
    $appDir = Join-Path $Source 'src\AdaptiveMedia.App'
    $proj = Join-Path $appDir 'AdaptiveMedia.App.csproj'
    $build = Join-Path $Source 'scripts\Build-Dev.ps1'
    if (-not (Test-Path $proj)) { throw "WPF project missing: $proj" }
    if (-not (Test-Path $build)) { throw "Build script missing: $build" }

    Ensure-Using (Join-Path $appDir 'App.xaml.cs') @('using System;','using System.IO;','using System.Linq;')
    Ensure-Using (Join-Path $appDir 'BackendBridge.cs') @('using System;','using System.Collections.Generic;','using System.IO;','using System.Threading.Tasks;')
    Ensure-Using (Join-Path $appDir 'MainWindow.xaml.cs') @('using System;','using System.Collections.Generic;','using System.Linq;','using System.Threading.Tasks;')
    Ensure-Using (Join-Path $appDir 'SettingsStore.cs') @('using System;','using System.IO;')
    Ensure-Using (Join-Path $appDir 'UrlDialog.xaml.cs') @('using System;')

    $program = @'
using System;
using System.IO;
using System.Linq;

namespace AdaptiveMedia;

internal static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        if (args.Any(a => string.Equals(a, "--self-test", StringComparison.OrdinalIgnoreCase)))
        {
            var baseDir = AppContext.BaseDirectory;
            var engine = Path.Combine(baseDir, "AdaptiveMedia.Engine.ps1");
            var config = Path.Combine(baseDir, "mpv-config", "mpv.conf");
            return Environment.Is64BitOperatingSystem &&
                   File.Exists(engine) &&
                   File.Exists(config) ? 0 : 11;
        }

        var app = new App();
        app.InitializeComponent();
        return app.Run();
    }
}
'@
    Write-Utf8NoBom (Join-Path $appDir 'Program.cs') $program

    $xml = [IO.File]::ReadAllText($proj)
    if ($xml -match '<StartupObject>.*?</StartupObject>') {
        $xml = [regex]::Replace($xml,'<StartupObject>.*?</StartupObject>','<StartupObject>AdaptiveMedia.Program</StartupObject>',1)
    } else {
        $xml = [regex]::Replace(
            $xml,
            '(<PropertyGroup(?:\s+[^>]*)?>)',
            '$1' + [Environment]::NewLine + '    <StartupObject>AdaptiveMedia.Program</StartupObject>',
            1
        )
    }
    Write-Utf8NoBom $proj $xml

    $b = [IO.File]::ReadAllText($build)
    $oldStage = @'
Step 'Launcher self-test'
& (Join-Path $Stage 'AdaptiveMedia.exe') --self-test
if ($LASTEXITCODE -ne 0) { throw "Native app self-test failed with exit code $LASTEXITCODE." }
Write-Host 'Native app self-test: PASS' -ForegroundColor Green
'@
    $newStage = @'
Step 'Launcher self-test'
$stageLauncher = Join-Path $Stage 'AdaptiveMedia.exe'
$selfTest = Start-Process -FilePath $stageLauncher -ArgumentList '--self-test' -Wait -PassThru
if ($selfTest.ExitCode -ne 0) { throw "Native app self-test failed with exit code $($selfTest.ExitCode)." }
Write-Host 'Native app self-test: PASS' -ForegroundColor Green
'@
    if ($b.Contains($oldStage)) { $b = $b.Replace($oldStage,$newStage) }

    $oldInstalled = @'
    & $smokeLauncher --self-test
    if ($LASTEXITCODE -ne 0) { throw "Installed app self-test failed with exit code $LASTEXITCODE." }
'@
    $newInstalled = @'
    $installedSelfTest = Start-Process -FilePath $smokeLauncher -ArgumentList '--self-test' -Wait -PassThru
    if ($installedSelfTest.ExitCode -ne 0) { throw "Installed app self-test failed with exit code $($installedSelfTest.ExitCode)." }
'@
    if ($b.Contains($oldInstalled)) { $b = $b.Replace($oldInstalled,$newInstalled) }
    Write-Utf8NoBom $build $b

    $main = Join-Path $appDir 'MainWindow.xaml'
    if (Test-Path $main) {
        $t = [IO.File]::ReadAllText($main)
        $t = [regex]::Replace($t,'v0\.3\.0-dev\d+','v0.3.0-dev5')
        Write-Utf8NoBom $main $t
    }
    $iss = Join-Path $Source 'installer\AdaptiveMedia.iss'
    if (Test-Path $iss) {
        $t = [IO.File]::ReadAllText($iss)
        $t = [regex]::Replace($t,'0\.3\.0-dev\d+','0.3.0-dev5')
        Write-Utf8NoBom $iss $t
    }
}

try {
    Banner 'Adaptive Media - current development build'
    New-Item -ItemType Directory -Force $Work,$TempRoot | Out-Null

    Write-Host 'Downloading current verified DevKit...' -ForegroundColor Gray
    Invoke-WebRequest -UseBasicParsing -Uri "$RepoBase/manifest.json" -OutFile $ManifestPath
    $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
    Invoke-WebRequest -UseBasicParsing -Uri "$RepoBase/AdaptiveMedia-DevKit.b64" -OutFile $B64
    $encoded = (Get-Content $B64 -Raw).Trim()
    [IO.File]::WriteAllBytes($Zip,[Convert]::FromBase64String($encoded))

    $actual = (Get-FileHash -Algorithm SHA256 $Zip).Hash.ToLowerInvariant()
    $expected = ([string]$manifest.sha256).ToLowerInvariant()
    if ($actual -ne $expected) { throw "DevKit integrity check failed. Expected $expected, got $actual." }
    Write-Host 'DevKit integrity check: PASS' -ForegroundColor Green

    Write-Host 'Staging fixed development workspace...' -ForegroundColor Gray
    Remove-Item -Recurse -Force $Extract -ErrorAction SilentlyContinue
    Expand-Archive -LiteralPath $Zip -DestinationPath $Extract -Force
    $root = Get-ChildItem $Extract -Directory | Select-Object -First 1
    if (-not $root) { throw 'Downloaded DevKit archive was empty.' }

    Remove-Item -Recurse -Force $Source -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $Source | Out-Null
    Copy-Item -Path (Join-Path $root.FullName '*') -Destination $Source -Recurse -Force

    Write-Host 'Applying current Windows-validation migrations...' -ForegroundColor Gray
    Apply-CurrentMigrations
    Write-Host 'Source migrations: PASS' -ForegroundColor Green

    Banner 'Building + smoke testing'
    $buildScript = Join-Path $Source 'scripts\Build-Dev.ps1'
    Remove-Item $Log -Force -ErrorAction SilentlyContinue

    try {
        & $buildScript -InstallTools -Clean -SmokeTest *>&1 | Tee-Object -FilePath $Log
    } catch {
        $_ | Out-String | Tee-Object -FilePath $Log -Append | Write-Host
        throw
    }

    $setup = Get-ChildItem (Join-Path $Source 'dist') -Filter 'AdaptiveMediaSetup-*.exe' -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $setup) { throw 'Build completed but no installer EXE was found.' }

    Banner 'BUILD + SMOKE TESTS PASSED'
    Write-Host "Installer: $($setup.FullName)" -ForegroundColor Green
    Write-Host "Log:       $Log" -ForegroundColor Gray
    Write-Host ''
    Write-Host 'Opening installer...' -ForegroundColor Cyan
    Start-Process -FilePath $setup.FullName
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'Adaptive Media development update FAILED.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ''
    Write-Host "Build log: $Log" -ForegroundColor Yellow
    Write-Host 'Upload that log here; no terminal work is required.' -ForegroundColor Yellow
    Write-Host ''
    Read-Host 'Press Enter to close'
    exit 1
}
