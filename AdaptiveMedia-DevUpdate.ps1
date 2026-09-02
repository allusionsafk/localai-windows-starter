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

    # Namespace imports discovered by the first real Windows compile.
    Ensure-Using (Join-Path $appDir 'BackendBridge.cs') @('using System;','using System.Collections.Generic;','using System.IO;','using System.Threading.Tasks;')
    Ensure-Using (Join-Path $appDir 'MainWindow.xaml.cs') @('using System;','using System.Collections.Generic;','using System.Linq;','using System.Threading.Tasks;')
    Ensure-Using (Join-Path $appDir 'SettingsStore.cs') @('using System;','using System.IO;')
    Ensure-Using (Join-Path $appDir 'UrlDialog.xaml.cs') @('using System;')

    # App.xaml already generates the AdaptiveMedia.App type. Keep its C#
    # code-behind empty and put ALL startup logic in Program. This avoids a
    # duplicate App declaration while still retaining the XAML resources.
    Write-Utf8NoBom (Join-Path $appDir 'App.xaml.cs') @'
// Intentionally empty. App.xaml generates AdaptiveMedia.App.
// Startup and --self-test handling live in Program.cs.
'@

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

        var window = new MainWindow(args);
        app.MainWindow = window;
        window.Show();

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

    # WPF generated sources live under obj. Remove every old generated file
    # whenever migrations change App/Program startup semantics.
    Remove-Item -Recurse -Force (Join-Path $appDir 'bin'),(Join-Path $appDir 'obj') -ErrorAction SilentlyContinue

    # Make the canonical build gates wait for the actual WinExe process.
    $b = [IO.File]::ReadAllText($build)
    $oldClean = @'
if ($Clean) { Remove-Item -Recurse -Force $Build,$Dist -ErrorAction SilentlyContinue }
'@
    $newClean = @'
if ($Clean) { Remove-Item -Recurse -Force $Build,$Dist,(Join-Path $Root 'src\AdaptiveMedia.App\bin'),(Join-Path $Root 'src\AdaptiveMedia.App\obj') -ErrorAction SilentlyContinue }
'@
    if ($b.Contains($oldClean)) { $b = $b.Replace($oldClean,$newClean) }
    $b = $b.Replace(
@" 
Step 'Launcher self-test'
& (Join-Path `$Stage 'AdaptiveMedia.exe') --self-test
if (`$LASTEXITCODE -ne 0) { throw "Native app self-test failed with exit code `$LASTEXITCODE." }
Write-Host 'Native app self-test: PASS' -ForegroundColor Green
"@,
@"
Step 'Launcher self-test'
`$stageLauncher = Join-Path `$Stage 'AdaptiveMedia.exe'
`$selfTest = Start-Process -FilePath `$stageLauncher -ArgumentList '--self-test' -Wait -PassThru
if (`$selfTest.ExitCode -ne 0) { throw "Native app self-test failed with exit code `$(`$selfTest.ExitCode)." }
Write-Host 'Native app self-test: PASS' -ForegroundColor Green
"@
    )
    $b = $b.Replace(
@"
    & `$smokeLauncher --self-test
    if (`$LASTEXITCODE -ne 0) { throw "Installed app self-test failed with exit code `$LASTEXITCODE." }
"@,
@"
    `$installedSelfTest = Start-Process -FilePath `$smokeLauncher -ArgumentList '--self-test' -Wait -PassThru
    if (`$installedSelfTest.ExitCode -ne 0) { throw "Installed app self-test failed with exit code `$(`$installedSelfTest.ExitCode)." }
"@
    )
    Write-Utf8NoBom $build $b

    # Current test label.
    $main = Join-Path $appDir 'MainWindow.xaml'
    if (Test-Path $main) {
        $t = [IO.File]::ReadAllText($main)
        $t = [regex]::Replace($t,'v0\.3\.0-dev\d+','v0.3.0-dev6')
        Write-Utf8NoBom $main $t
    }
    $iss = Join-Path $Source 'installer\AdaptiveMedia.iss'
    if (Test-Path $iss) {
        $t = [IO.File]::ReadAllText($iss)
        $t = [regex]::Replace($t,'0\.3\.0-dev\d+','0.3.0-dev6')
        Write-Utf8NoBom $iss $t
    }
}

try {
    Banner 'Adaptive Media - current development build'

    New-Item -ItemType Directory -Force $Work,$TempRoot | Out-Null

    Write-Host 'Downloading current verified DevKit...' -ForegroundColor Gray
    Invoke-WebRequest -UseBasicParsing -Headers @{'Cache-Control'='no-cache'} -Uri "$RepoBase/manifest.json?cb=$([DateTime]::UtcNow.Ticks)" -OutFile $ManifestPath
    $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json

    # Fetch the DevKit payload through GitHub's Contents API first. The API
    # returns the repository file itself as Base64, so this is intentionally a
    # two-step decode:
    #   API content (Base64) -> AdaptiveMedia-DevKit.b64 text -> DevKit ZIP.
    # This avoids treating an HTML/proxy/rate-limit response from a raw-content
    # CDN as if it were the DevKit. A validated raw-content fallback remains for
    # temporary GitHub API rate-limit failures.
    $innerBase64 = $null
    $apiUri = 'https://api.github.com/repos/allusionsafk/localai-windows-starter/contents/AdaptiveMedia-DevKit.b64?ref=adaptive-media-dev'
    try {
        $api = Invoke-RestMethod -UseBasicParsing -Headers @{
            'Accept'='application/vnd.github+json'
            'User-Agent'='AdaptiveMedia-Dev-Updater'
            'Cache-Control'='no-cache'
        } -Uri $apiUri

        if ($api.encoding -ne 'base64' -or [string]::IsNullOrWhiteSpace([string]$api.content)) {
            throw 'GitHub Contents API returned an unexpected payload encoding.'
        }

        $outer = ([string]$api.content) -replace '\s',''
        if ($outer -notmatch '^[A-Za-z0-9+/]*={0,2}$' -or ($outer.Length % 4) -ne 0) {
            throw 'GitHub Contents API returned malformed outer Base64.'
        }

        $innerBase64 = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($outer))
        Write-Host 'DevKit transport: GitHub Contents API' -ForegroundColor Gray
    }
    catch {
        Write-Host ('Contents API unavailable; trying validated raw fallback: ' + $_.Exception.Message) -ForegroundColor Yellow
        $rawUri = "$RepoBase/AdaptiveMedia-DevKit.b64?cb=$([DateTime]::UtcNow.Ticks)"
        $response = Invoke-WebRequest -UseBasicParsing -Headers @{'Cache-Control'='no-cache'} -Uri $rawUri
        $candidate = [string]$response.Content

        # Raw Base64 may contain CR/LF but nothing else.
        if ([string]::IsNullOrWhiteSpace($candidate) -or
            $candidate -match '[^A-Za-z0-9+/=\r\n\t ]') {
            $preview = ($candidate -replace '[\r\n]+',' ')
            if ($preview.Length -gt 120) { $preview = $preview.Substring(0,120) }
            throw "DevKit download was not Base64 data. Response preview: $preview"
        }
        $innerBase64 = $candidate
        Write-Host 'DevKit transport: validated raw fallback' -ForegroundColor Gray
    }

    $encoded = ($innerBase64 -replace '\s','')
    if ($encoded -notmatch '^[A-Za-z0-9+/]*={0,2}$' -or ($encoded.Length % 4) -ne 0) {
        throw 'Downloaded DevKit payload failed Base64 validation before decode.'
    }

    try {
        [IO.File]::WriteAllBytes($Zip,[Convert]::FromBase64String($encoded))
    }
    catch {
        throw "Validated DevKit Base64 still failed to decode: $($_.Exception.Message)"
    }

    # ZIP local-file signatures start with PK. Catch transport corruption before
    # relying on the checksum message to explain a non-ZIP payload.
    $zipBytes = [IO.File]::ReadAllBytes($Zip)
    if ($zipBytes.Length -lt 4 -or $zipBytes[0] -ne 0x50 -or $zipBytes[1] -ne 0x4B) {
        throw 'Decoded DevKit payload is not a ZIP archive.'
    }

    $actual = (Get-FileHash -Algorithm SHA256 $Zip).Hash.ToLowerInvariant()
    $expected = ([string]$manifest.sha256).ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "DevKit integrity check failed. Expected $expected, got $actual."
    }
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
        & $buildScript -InstallTools -Clean -SmokeTest *>&1 |
            Tee-Object -FilePath $Log
    }
    catch {
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
