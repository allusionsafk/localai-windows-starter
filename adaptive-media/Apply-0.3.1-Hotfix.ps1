#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot
)

$ErrorActionPreference = 'Stop'

function Read-Text([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "Required source file not found: $Path" }
    return [IO.File]::ReadAllText($Path)
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Replace-Exact([string]$Path, [string]$Old, [string]$New, [int]$ExpectedCount = 1) {
    $text = Read-Text $Path
    $count = ([regex]::Matches($text, [regex]::Escape($Old))).Count
    if ($count -ne $ExpectedCount) {
        throw "Expected $ExpectedCount occurrence(s) of '$Old' in $Path, found $count."
    }
    Write-Utf8NoBom $Path ($text.Replace($Old, $New))
}

$engine  = Join-Path $SourceRoot 'payload\AdaptiveMedia.Engine.ps1'
$iss     = Join-Path $SourceRoot 'installer\AdaptiveMedia.iss'
$proj    = Join-Path $SourceRoot 'src\AdaptiveMedia.App\AdaptiveMedia.App.csproj'
$xaml    = Join-Path $SourceRoot 'src\AdaptiveMedia.App\MainWindow.xaml'
$program = Join-Path $SourceRoot 'src\AdaptiveMedia.App\Program.cs'
$readme  = Join-Path $SourceRoot 'README.md'
$mpvConf = Join-Path $SourceRoot 'payload\mpv-config\mpv.conf'
$input   = Join-Path $SourceRoot 'payload\mpv-config\input.conf'

# mpv's video-sync-max-factor option is constrained to the inclusive range 1..10.
# 0.3.0 accidentally emitted 12 for both motion modes, so mpv rejected the command
# line at startup and exited with code 1 before playback began.
Replace-Exact $engine "--video-sync-max-factor=12" "--video-sync-max-factor=10" 2

# Stable patch version metadata.
Replace-Exact $iss  '#define MyAppVersion "0.3.0"' '#define MyAppVersion "0.3.1"'
Replace-Exact $iss  'VersionInfoVersion=0.3.0.0' 'VersionInfoVersion=0.3.1.0'
Replace-Exact $iss  'VersionInfoProductVersion=0.3.0.0' 'VersionInfoProductVersion=0.3.1.0'
Replace-Exact $proj '<InformationalVersion>0.3.0</InformationalVersion>' '<InformationalVersion>0.3.1</InformationalVersion>'
Replace-Exact $proj '<FileVersion>0.3.0.0</FileVersion>' '<FileVersion>0.3.1.0</FileVersion>'
Replace-Exact $proj '<AssemblyVersion>0.3.0.0</AssemblyVersion>' '<AssemblyVersion>0.3.1.0</AssemblyVersion>'
Replace-Exact $xaml 'Text="v0.3.0"' 'Text="v0.3.1"'
Replace-Exact $readme '# Adaptive Media 0.3.0' '# Adaptive Media 0.3.1'
Replace-Exact $readme 'AdaptiveMediaSetup-0.3.0-x64.exe' 'AdaptiveMediaSetup-0.3.1-x64.exe'
Replace-Exact $mpvConf '# Adaptive Media 0.3.0 - managed mpv defaults' '# Adaptive Media 0.3.1 - managed mpv defaults'
Replace-Exact $input '# Adaptive Media 0.3.0' '# Adaptive Media 0.3.1'

# Strengthen the built-in integration gate so this exact regression cannot ship again.
$programText = Read-Text $program
$oldEnhanced = @'
            if (!Has(enhanced, "--scale=ewa_lanczossharp") ||
                !Has(enhanced, "--sigmoid-upscaling=yes") ||
                !Has(enhanced, "--video-sync=display-resample") ||
                !Has(enhanced, "--interpolation=yes") ||
                !Has(enhanced, "--deband=yes"))
                return 22;
'@
$newEnhanced = @'
            if (!Has(enhanced, "--scale=ewa_lanczossharp") ||
                !Has(enhanced, "--sigmoid-upscaling=yes") ||
                !Has(enhanced, "--video-sync=display-resample") ||
                !Has(enhanced, "--video-sync-max-factor=10") ||
                !Has(enhanced, "--interpolation=yes") ||
                !Has(enhanced, "--deband=yes"))
                return 22;

            var gentle = await backend.GetPlaybackPlanAsync(
                syntheticUrl, new PlaybackOptions("Automatic", "Off", "Gentle", false, false));
            if (!Has(gentle, "--video-sync=display-resample") ||
                !Has(gentle, "--video-sync-max-factor=10") ||
                !Has(gentle, "--interpolation=yes") ||
                !Has(gentle, "--tscale=oversample") ||
                gentle.Arguments.Any(a => string.Equals(a, "--video-sync-max-factor=12", StringComparison.OrdinalIgnoreCase)))
                return 24;
'@
if (-not $programText.Contains($oldEnhanced)) {
    throw 'Expected 0.3.0 integration-test block was not found; refusing to weaken the gate.'
}
Write-Utf8NoBom $program ($programText.Replace($oldEnhanced, $newEnhanced))

# Fail closed on the actual regression and version contract.
$verifyEngine = Read-Text $engine
if ($verifyEngine -match '--video-sync-max-factor=12') { throw 'Invalid motion max-factor 12 remains after hotfix.' }
if (([regex]::Matches($verifyEngine, [regex]::Escape('--video-sync-max-factor=10'))).Count -ne 2) {
    throw 'Expected both Gentle and Smooth motion lanes to use max-factor 10.'
}
$verifyIss = Read-Text $iss
if ($verifyIss -notmatch '#define MyAppVersion "0\.3\.1"' -or $verifyIss -notmatch 'VersionInfoVersion=0\.3\.1\.0') {
    throw '0.3.1 installer version verification failed.'
}
$verifyProgram = Read-Text $program
if ($verifyProgram -notmatch 'new PlaybackOptions\("Automatic", "Off", "Gentle"' -or $verifyProgram -notmatch '--video-sync-max-factor=10') {
    throw '0.3.1 motion integration regression coverage was not installed.'
}

Write-Host 'Adaptive Media 0.3.1 motion hotfix applied and verified.'
