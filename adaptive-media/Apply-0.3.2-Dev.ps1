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
#
# The engine stores each native argument as one collection element. Keep FIFO
# as its own Add() call; passing two strings to Add() is invalid PowerShell/.NET.
$engineText = Read-Text $engine
$displayAddPattern = '(?m)^(\s*)(\$[A-Za-z_][A-Za-z0-9_]*)\.Add\(''--video-sync=display-resample''\)\s*$'
$displayAddMatches = [regex]::Matches($engineText, $displayAddPattern)
if ($displayAddMatches.Count -ne 2) {
    throw "Expected exactly two display-resample Add() motion lanes after 0.3.1; found $($displayAddMatches.Count)."
}
$engineText = [regex]::Replace(
    $engineText,
    $displayAddPattern,
    { param($m)
        $indent = $m.Groups[1].Value
        $list = $m.Groups[2].Value
        return $indent + $list + ".Add('--video-sync=display-resample')" + [Environment]::NewLine +
               $indent + $list + ".Add('--vulkan-swap-mode=fifo')"
    }
)
Write-Utf8NoBom $engine $engineText

# ---------------------------------------------------------------------------
# 0.3.2 dev: decode native UTF-8 tool output explicitly in diagnostics.
# ---------------------------------------------------------------------------
# Windows PowerShell 5.1 decodes direct native-pipeline output through the
# console code page. mpv emits UTF-8, so C2 A9 (copyright sign) was shown as
# CP437 box-drawing glyphs. Capture native stdout through ProcessStartInfo and
# explicitly request UTF-8 decoding instead.
$diagMarker = 'function Write-Diagnostics {'
$utf8Helper = @'
function Get-NativeUtf8FirstLine {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)][string[]]$Arguments
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    $psi.WorkingDirectory = Split-Path -Parent $FilePath
    $psi.Arguments = (($Arguments | ForEach-Object { ConvertTo-NativeArgument ([string]$_) }) -join ' ')

    $process = [System.Diagnostics.Process]::Start($psi)
    if (-not $process) { throw "Could not start native diagnostics tool: $FilePath" }
    try {
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw $(if ([string]::IsNullOrWhiteSpace($stderr)) { "Native diagnostics tool exited with code $($process.ExitCode)." } else { $stderr.Trim() })
        }
        return (($stdout -split "`r?`n") | Select-Object -First 1)
    }
    finally {
        $process.Dispose()
    }
}

function Write-Diagnostics {
'@
Replace-Exact $engine $diagMarker $utf8Helper

$oldMpvVersion = '    if ($mpv) { try { $lines.Add(''MPV version: '' + ((& $mpv --no-config --version | Select-Object -First 1) -join '''')) } catch {} }'
$newMpvVersion = '    if ($mpv) { try { $lines.Add(''MPV version: '' + (Get-NativeUtf8FirstLine $mpv @(''--no-config'',''--version''))) } catch {} }'
Replace-Exact $engine $oldMpvVersion $newMpvVersion

# Make multi-adapter diagnostics useful without pretending Win32_VideoController
# proves active display ownership. This is only an informational topology hint.
$oldGpuDiag = '    try { $lines.Add(''GPU(s): '' + ((Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name + '' driver '' + $_.DriverVersion }) -join ''; '')) } catch {}'
$newGpuDiag = @'
    try {
        $diagGpus = @(Get-CimInstance Win32_VideoController)
        $lines.Add('GPU(s): ' + (($diagGpus | ForEach-Object { $_.Name + ' driver ' + $_.DriverVersion }) -join '; '))
        if ($diagGpus.Count -gt 1) {
            $hasNvidia = @($diagGpus | Where-Object { $_.Name -match 'NVIDIA' }).Count -gt 0
            $hasIntel = @($diagGpus | Where-Object { $_.Name -match 'Intel' }).Count -gt 0
            $hint = if ($hasNvidia -and $hasIntel) {
                'possible NVIDIA + Intel hybrid/MUX topology'
            } else {
                'multiple graphics adapters detected'
            }
            $lines.Add('Graphics topology hint: ' + $hint + '; this does not prove which adapter currently owns the display path.')
        }
    } catch {}
'@
Replace-Exact $engine $oldGpuDiag $newGpuDiag

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

# The stable integration harness writes exceptions to stderr, but WinExe
# smoke invocation can hide that stream. Persist the dev exception in TEMP so
# Actions can surface the real cause without weakening the integration gate.
$catchNeedle = '            Console.Error.WriteLine(ex);'
$catchNew = $catchNeedle + [Environment]::NewLine + '            try { System.IO.File.WriteAllText(System.IO.Path.Combine(System.IO.Path.GetTempPath(), "AdaptiveMedia-0.3.2-integration-error.txt"), ex.ToString()); } catch { }'
Replace-Exact $program $catchNeedle $catchNew

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
if (([regex]::Matches($verifyEngine, [regex]::Escape(".Add('--vulkan-swap-mode=fifo')"))).Count -ne 2) {
    throw 'Expected both Gentle and Smooth motion lanes to add Vulkan FIFO as a separate argument.'
}
if ($verifyEngine -match '--video-sync-max-factor=12') {
    throw 'Invalid 0.3.0 motion max-factor 12 reappeared.'
}
if ($verifyEngine -match "\.Add\('--video-sync=display-resample'\s*,") {
    throw 'Invalid multi-argument Add() form remains in the 0.3.2 engine.'
}
if (-not $verifyEngine.Contains('StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)')) {
    throw '0.3.2 diagnostics UTF-8 native-output decoding is missing.'
}
if ($verifyEngine.Contains('& $mpv --no-config --version')) {
    throw '0.3.2 diagnostics still directly pipes mpv version output through the PowerShell console code page.'
}
if (-not $verifyEngine.Contains('Graphics topology hint: ')) {
    throw '0.3.2 multi-adapter diagnostics hint is missing.'
}

$verifyProgram = Read-Text $program
if (([regex]::Matches($verifyProgram, [regex]::Escape('--vulkan-swap-mode=fifo'))).Count -lt 2) {
    throw '0.3.2 integration gate does not cover FIFO for both motion modes.'
}
if (-not $verifyProgram.Contains('AdaptiveMedia-0.3.2-integration-error.txt')) {
    throw '0.3.2 dev integration exception capture is missing.'
}

Write-Host 'Adaptive Media 0.3.2-dev1 fullscreen, motion-presentation, and diagnostics fixes applied and verified.'
