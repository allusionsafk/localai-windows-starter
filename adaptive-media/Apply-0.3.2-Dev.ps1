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
        throw "Expected $ExpectedCount occurrence(s) in $Path, found $count. Needle: $Old"
    }
    Write-Utf8NoBom $Path ($text.Replace($Old, $New))
}

$engine  = Join-Path $SourceRoot 'payload\AdaptiveMedia.Engine.ps1'
$input   = Join-Path $SourceRoot 'payload\mpv-config\input.conf'
$iss     = Join-Path $SourceRoot 'installer\AdaptiveMedia.iss'
$proj    = Join-Path $SourceRoot 'src\AdaptiveMedia.App\AdaptiveMedia.App.csproj'
$xaml    = Join-Path $SourceRoot 'src\AdaptiveMedia.App\MainWindow.xaml'
$program = Join-Path $SourceRoot 'src\AdaptiveMedia.App\Program.cs'
$readme  = Join-Path $SourceRoot 'README.md'
$mpvConf = Join-Path $SourceRoot 'payload\mpv-config\mpv.conf'

# ---------------------------------------------------------------------------
# 0.3.2 dev: ESC must leave fullscreen, never quit playback.
# ---------------------------------------------------------------------------
# mpv's built-in ESC binding is `set fullscreen no`. A managed input.conf can
# override that weak built-in binding, so make the Adaptive Media policy
# explicit and fail closed against any active ESC quit binding.
$inputText = Read-Text $input
$activeEsc = [regex]::Matches($inputText, '(?m)^(?!\s*#)\s*ESC\s+[^\r\n]+')
if ($activeEsc.Count -gt 0) {
    $inputText = [regex]::Replace($inputText, '(?m)^(?!\s*#)\s*ESC\s+[^\r\n]+', 'ESC set fullscreen no')
} else {
    if (-not $inputText.EndsWith("`n")) { $inputText += [Environment]::NewLine }
    $inputText += 'ESC set fullscreen no' + [Environment]::NewLine
}
Write-Utf8NoBom $input $inputText

# ---------------------------------------------------------------------------
# 0.3.2 dev: make Vulkan presentation mode explicit for display-sync motion.
# ---------------------------------------------------------------------------
# mpv documents that display-* video-sync modes require a vsync-blocked
# presentation mode; for Vulkan that is fifo (or fifo-relaxed). 0.3.1 relied
# on auto selection, which behaved badly on the tested Optimus presentation
# path while dGPU-only mode behaved normally.
$engineText = Read-Text $engine
$displaySyncCount = ([regex]::Matches($engineText, [regex]::Escape("'--video-sync=display-resample'"))).Count
if ($displaySyncCount -ne 2) {
    throw "Expected exactly two display-resample motion lanes after 0.3.1; found $displaySyncCount."
}
$engineText = $engineText.Replace("'--video-sync=display-resample'", "'--video-sync=display-resample','--vulkan-swap-mode=fifo'")
Write-Utf8NoBom $engine $engineText

# ---------------------------------------------------------------------------
# 0.3.2 dev version metadata. This is an internal candidate, not a release.
# ---------------------------------------------------------------------------
Replace-Exact $iss  '#define MyAppVersion "0.3.1"' '#define MyAppVersion "0.3.2-dev1"'
Replace-Exact $iss  'VersionInfoVersion=0.3.1.0' 'VersionInfoVersion=0.3.2.0'
Replace-Exact $iss  'VersionInfoProductVersion=0.3.1.0' 'VersionInfoProductVersion=0.3.2.0'
Replace-Exact $proj '<InformationalVersion>0.3.1</InformationalVersion>' '<InformationalVersion>0.3.2-dev1</InformationalVersion>'
Replace-Exact $proj '<FileVersion>0.3.1.0</FileVersion>' '<FileVersion>0.3.2.0</FileVersion>'
Replace-Exact $proj '<AssemblyVersion>0.3.1.0</AssemblyVersion>' '<AssemblyVersion>0.3.2.0</AssemblyVersion>'
Replace-Exact $xaml 'Text="v0.3.1"' 'Text="v0.3.2-dev1"'
Replace-Exact $readme '# Adaptive Media 0.3.1' '# Adaptive Media 0.3.2-dev1'
Replace-Exact $readme 'AdaptiveMediaSetup-0.3.1-x64.exe' 'AdaptiveMediaSetup-0.3.2-dev1-x64.exe'
Replace-Exact $mpvConf '# Adaptive Media 0.3.1 - managed mpv defaults' '# Adaptive Media 0.3.2-dev1 - managed mpv defaults'
Replace-Exact $input '# Adaptive Media 0.3.1' '# Adaptive Media 0.3.2-dev1'

# ---------------------------------------------------------------------------
# Clarify what the current motion feature actually is.
# ---------------------------------------------------------------------------
# Keep labels compact; tooltips should not imply AI/optical-flow frame gen.
Replace-Exact $xaml 'ToolTip="Light interpolation to reduce judder while keeping a more natural look."' 'ToolTip="Light temporal interpolation to reduce judder. This is mpv cadence smoothing, not AI optical-flow frame generation."'
Replace-Exact $xaml 'ToolTip="Stronger interpolation for maximum smoothness; may create a soap-opera look."' 'ToolTip="Stronger temporal interpolation for smoother cadence; may create a soap-opera look. This is not AI optical-flow frame generation."'

# ---------------------------------------------------------------------------
# Built-in integration regression coverage.
# ---------------------------------------------------------------------------
$enhancedNeedle = '                !Has(enhanced, "--video-sync-max-factor=10") ||'
$enhancedNew = $enhancedNeedle + [Environment]::NewLine + '                !Has(enhanced, "--vulkan-swap-mode=fifo") ||'
Replace-Exact $program $enhancedNeedle $enhancedNew

$gentleNeedle = '                !Has(gentle, "--video-sync-max-factor=10") ||'
$gentleNew = $gentleNeedle + [Environment]::NewLine + '                !Has(gentle, "--vulkan-swap-mode=fifo") ||'
Replace-Exact $program $gentleNeedle $gentleNew

# ---------------------------------------------------------------------------
# Fail-closed verification.
# ---------------------------------------------------------------------------
$verifyInput = Read-Text $input
if ($verifyInput -notmatch '(?m)^ESC\s+set\s+fullscreen\s+no\s*$') {
    throw '0.3.2 dev ESC fullscreen binding is missing.'
}
if ($verifyInput -match '(?im)^\s*ESC\s+.*\bquit(?:-watch-later)?\b') {
    throw '0.3.2 dev still contains an ESC quit binding.'
}

$verifyEngine = Read-Text $engine
if (([regex]::Matches($verifyEngine, [regex]::Escape('--vulkan-swap-mode=fifo'))).Count -ne 2) {
    throw 'Expected both Gentle and Smooth motion lanes to force Vulkan FIFO presentation.'
}
if ($verifyEngine -match '--video-sync-max-factor=12') {
    throw 'Invalid 0.3.0 motion max-factor 12 reappeared.'
}

$verifyProgram = Read-Text $program
if (([regex]::Matches($verifyProgram, [regex]::Escape('--vulkan-swap-mode=fifo'))).Count -lt 2) {
    throw '0.3.2 integration gate does not cover FIFO for both motion modes.'
}

Write-Host 'Adaptive Media 0.3.2-dev1 fullscreen and motion-presentation fixes applied and verified.'
