$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Work = Join-Path $env:LOCALAPPDATA 'AdaptiveMediaDev'
$Source = Join-Path $Work 'source'
$Log = Join-Path $Work 'last-build.log'
$AppDir = Join-Path $Source 'src\AdaptiveMedia.App'
$Proj = Join-Path $AppDir 'AdaptiveMedia.App.csproj'
$BuildScript = Join-Path $Source 'scripts\Build-Dev.ps1'

function Write-Utf8NoBom([string]$Path,[string]$Text) {
    [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))
}

function Ensure-Using([string]$Path,[string[]]$Usings) {
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

function Say([string]$Text) {
    Write-Host $Text
    Add-Content -LiteralPath $Log -Value $Text -Encoding UTF8
}

New-Item -ItemType Directory -Force $Work | Out-Null
Set-Content -LiteralPath $Log -Value ("Adaptive Media updater started: " + (Get-Date -Format o)) -Encoding UTF8

try {
    Write-Host ''
    Write-Host '================================================================' -ForegroundColor Cyan
    Write-Host ' Adaptive Media v0.3.0-dev8 - workspace repair + build' -ForegroundColor Cyan
    Write-Host '================================================================' -ForegroundColor Cyan
    Write-Host ''

    Say "Workspace: $Source"
    Say "Log:       $Log"

    if (-not (Test-Path $Proj) -or -not (Test-Path $BuildScript)) {
        throw "Existing development workspace is incomplete. Expected $Proj and $BuildScript."
    }

    Say 'Existing source workspace found. Skipping DevKit transport.'
    Say 'Applying WPF startup migrations...'

    Ensure-Using (Join-Path $AppDir 'BackendBridge.cs') @(
        'using System;',
        'using System.Collections.Generic;',
        'using System.IO;',
        'using System.Threading.Tasks;'
    )
    Ensure-Using (Join-Path $AppDir 'MainWindow.xaml.cs') @(
        'using System;',
        'using System.Collections.Generic;',
        'using System.Linq;',
        'using System.Threading.Tasks;'
    )
    Ensure-Using (Join-Path $AppDir 'SettingsStore.cs') @('using System;','using System.IO;')
    Ensure-Using (Join-Path $AppDir 'UrlDialog.xaml.cs') @('using System;')

    # App.xaml generates AdaptiveMedia.App. Do not declare App again.
    $emptyAppCodeBehind = @'
// Intentionally empty. App.xaml generates AdaptiveMedia.App.
// Startup and --self-test handling live in Program.cs.
'@
    Write-Utf8NoBom (Join-Path $AppDir 'App.xaml.cs') $emptyAppCodeBehind

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
    Write-Utf8NoBom (Join-Path $AppDir 'Program.cs') $program

    $xml = [IO.File]::ReadAllText($Proj)
    if ($xml -match '<StartupObject>.*?</StartupObject>') {
        $xml = [regex]::Replace(
            $xml,
            '<StartupObject>.*?</StartupObject>',
            '<StartupObject>AdaptiveMedia.Program</StartupObject>',
            1
        )
    }
    else {
        $xml = [regex]::Replace(
            $xml,
            '(<PropertyGroup(?:\s+[^>]*)?>)',
            '$1' + [Environment]::NewLine + '    <StartupObject>AdaptiveMedia.Program</StartupObject>',
            1
        )
    }
    Write-Utf8NoBom $Proj $xml

    # Clear WPF generated sources so stale App.g.cs output cannot survive.
    Remove-Item -Recurse -Force `
        (Join-Path $AppDir 'bin'), `
        (Join-Path $AppDir 'obj') `
        -ErrorAction SilentlyContinue

    Say 'Hardening Build-Dev.ps1 self-test process handling...'
    $b = [IO.File]::ReadAllText($BuildScript)

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
    if ($b.Contains($oldStage)) {
        $b = $b.Replace($oldStage,$newStage)
        Say 'Staging self-test gate migration: APPLIED'
    }
    elseif ($b.Contains('$selfTest = Start-Process -FilePath $stageLauncher')) {
        Say 'Staging self-test gate migration: ALREADY PRESENT'
    }
    else {
        Say 'Staging self-test gate migration: source shape unknown; independent post-build test will remain authoritative.'
    }

    $oldInstalled = @'
    & $smokeLauncher --self-test
    if ($LASTEXITCODE -ne 0) { throw "Installed app self-test failed with exit code $LASTEXITCODE." }
'@
    $newInstalled = @'
    $installedSelfTest = Start-Process -FilePath $smokeLauncher -ArgumentList '--self-test' -Wait -PassThru
    if ($installedSelfTest.ExitCode -ne 0) { throw "Installed app self-test failed with exit code $($installedSelfTest.ExitCode)." }
'@
    if ($b.Contains($oldInstalled)) {
        $b = $b.Replace($oldInstalled,$newInstalled)
        Say 'Installed self-test gate migration: APPLIED'
    }
    elseif ($b.Contains('$installedSelfTest = Start-Process -FilePath $smokeLauncher')) {
        Say 'Installed self-test gate migration: ALREADY PRESENT'
    }
    else {
        Say 'Installed self-test gate migration: source shape unknown.'
    }

    Write-Utf8NoBom $BuildScript $b

    $main = Join-Path $AppDir 'MainWindow.xaml'
    if (Test-Path $main) {
        $t = [IO.File]::ReadAllText($main)
        $t = [regex]::Replace($t,'v0\.3\.0-dev\d+','v0.3.0-dev8')
        Write-Utf8NoBom $main $t
    }

    $iss = Join-Path $Source 'installer\AdaptiveMedia.iss'
    if (Test-Path $iss) {
        $t = [IO.File]::ReadAllText($iss)
        $t = [regex]::Replace($t,'0\.3\.0-dev\d+','0.3.0-dev8')
        Write-Utf8NoBom $iss $t
    }

    if ((Get-Content (Join-Path $AppDir 'App.xaml.cs') -Raw) -match 'class\s+App') {
        throw 'App.xaml.cs still declares App after migration.'
    }
    if ((Get-Content (Join-Path $AppDir 'Program.cs') -Raw) -notmatch 'namespace AdaptiveMedia;') {
        throw 'Program.cs namespace migration failed.'
    }
    if ((Get-Content $Proj -Raw) -notmatch '<StartupObject>AdaptiveMedia\.Program</StartupObject>') {
        throw 'StartupObject migration failed.'
    }

    Say 'Migration assertions: PASS'
    Say 'Building WPF app and installer...'

    & $BuildScript -InstallTools -Clean -SmokeTest *>&1 |
        Tee-Object -FilePath $Log -Append

    $launcher = Join-Path $Source 'build\staging\AdaptiveMedia.exe'
    if (-not (Test-Path $launcher)) {
        throw "Built launcher not found: $launcher"
    }

    Say 'Running independent strict launcher self-test...'
    $p = Start-Process -FilePath $launcher -ArgumentList '--self-test' -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        throw "Independent launcher self-test failed with exit code $($p.ExitCode)."
    }
    Say 'Independent launcher self-test: PASS'

    $setup = Get-ChildItem (Join-Path $Source 'dist') -Filter 'AdaptiveMediaSetup-*.exe' -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $setup) {
        throw 'No installer EXE was produced.'
    }

    Say ("Installer: " + $setup.FullName)
    Write-Host ''
    Write-Host 'BUILD + SMOKE TESTS PASSED' -ForegroundColor Green
    Write-Host 'Opening installer...' -ForegroundColor Cyan
    Start-Process -FilePath $setup.FullName
    exit 0
}
catch {
    $msg = 'FAILED: ' + $_.Exception.Message
    Write-Host ''
    Write-Host $msg -ForegroundColor Red
    Add-Content -LiteralPath $Log -Value $msg -Encoding UTF8
    Add-Content -LiteralPath $Log -Value ($_ | Out-String) -Encoding UTF8
    Write-Host ''
    Write-Host "This run updated the log: $Log" -ForegroundColor Yellow
    Write-Host 'Upload that file if the next step fails.' -ForegroundColor Yellow
    Write-Host ''
    Read-Host 'Press Enter to close'
    exit 1
}
