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
# 0.3.2 dev: make display-sync presentation renderer-aware.
# ---------------------------------------------------------------------------
# mpv requires a vsync-blocked Vulkan swapchain for display-* video-sync modes.
# The managed default renderer is Vulkan and the NVIDIA profile is explicit
# winvk, but Compatibility and NVIDIA RTX VPP intentionally select D3D11.
# Therefore FIFO belongs at the end of enhancement planning, after all renderer
# overrides are known, not inside the early Gentle/Smooth branches.
$engineText = Read-Text $engine
$displayAddPattern = '(?m)^\s*\$MpvArgs\.Add\(''--video-sync=display-resample''\)\s*$'
if (([regex]::Matches($engineText, $displayAddPattern)).Count -ne 2) {
    throw 'Expected exactly two display-resample motion lanes after 0.3.1.'
}

$vppTail = @'
    if ($vpp.Count -gt 0) {
        # d3d11vpp is intentionally an opt-in path because the validated reference
        # path on hybrid NVIDIA laptops is winvk + NVDEC. RTX VSR/HDR require D3D11 VPP.
        $MpvArgs.Add('--gpu-context=d3d11')
        $MpvArgs.Add('--hwdec=d3d11va,auto')
        $MpvArgs.Add('--vf=d3d11vpp=' + ($vpp -join ':'))
    }
}
'@
$vppTailWithPresentation = @'
    if ($vpp.Count -gt 0) {
        # d3d11vpp is intentionally an opt-in path because the validated reference
        # path on hybrid NVIDIA laptops is winvk + NVDEC. RTX VSR/HDR require D3D11 VPP.
        $MpvArgs.Add('--gpu-context=d3d11')
        $MpvArgs.Add('--hwdec=d3d11va,auto')
        $MpvArgs.Add('--vf=d3d11vpp=' + ($vpp -join ':'))
    }

    # Decide presentation mode only after every optional renderer override is known.
    # Compatibility is explicit D3D11 through mpv.conf. RTX VPP adds an explicit
    # D3D11 context above. All other managed motion paths retain the Vulkan default.
    $motionUsesDisplaySync = ($Motion -eq 'Gentle' -or $Motion -eq 'Smooth')
    $finalUsesD3d11 = $MpvArgs.Contains('--profile=compatibility') -or $MpvArgs.Contains('--gpu-context=d3d11')
    if ($motionUsesDisplaySync -and -not $finalUsesD3d11) {
        $MpvArgs.Add('--vulkan-swap-mode=fifo')
    }
}
'@
Replace-Exact $engine $vppTail $vppTailWithPresentation

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
# 0.3.2 dev2 version metadata. This remains an internal candidate.
# ---------------------------------------------------------------------------
Replace-Exact $iss  '#define MyAppVersion "0.3.1"' '#define MyAppVersion "0.3.2-dev2"'
Replace-Exact $iss  'VersionInfoVersion=0.3.1.0' 'VersionInfoVersion=0.3.2.0'
Replace-Exact $iss  'VersionInfoProductVersion=0.3.1.0' 'VersionInfoProductVersion=0.3.2.0'
Replace-Exact $proj '<InformationalVersion>0.3.1</InformationalVersion>' '<InformationalVersion>0.3.2-dev2</InformationalVersion>'
Replace-Exact $proj '<FileVersion>0.3.1.0</FileVersion>' '<FileVersion>0.3.2.0</FileVersion>'
Replace-Exact $proj '<AssemblyVersion>0.3.1.0</AssemblyVersion>' '<AssemblyVersion>0.3.2.0</AssemblyVersion>'
Replace-Exact $xaml 'Text="v0.3.1"' 'Text="v0.3.2-dev2"'
Replace-Exact $readme '# Adaptive Media 0.3.1' '# Adaptive Media 0.3.2-dev2'
Replace-Exact $readme 'AdaptiveMediaSetup-0.3.1-x64.exe' 'AdaptiveMediaSetup-0.3.2-dev2-x64.exe'
Replace-Exact $mpvConf '# Adaptive Media 0.3.1 - managed mpv defaults' '# Adaptive Media 0.3.2-dev2 - managed mpv defaults'
Replace-Exact $input '# Adaptive Media 0.3.1' '# Adaptive Media 0.3.2-dev2'

# ---------------------------------------------------------------------------
# Clarify what the current motion feature actually is.
# ---------------------------------------------------------------------------
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

$compatMarker = '            var compatibility = await backend.GetPlaybackPlanAsync('
$compatSmooth = @'
            var compatibilitySmooth = await backend.GetPlaybackPlanAsync(
                syntheticUrl, new PlaybackOptions("Compatibility", "Off", "Smooth", false, false));
            if (!Has(compatibilitySmooth, "--profile=compatibility") ||
                !Has(compatibilitySmooth, "--video-sync=display-resample") ||
                !Has(compatibilitySmooth, "--interpolation=yes") ||
                Has(compatibilitySmooth, "--vulkan-swap-mode=fifo"))
                return 25;

'@
Replace-Exact $program $compatMarker ($compatSmooth + $compatMarker)

# The stable integration harness writes exceptions to stderr, but WinExe smoke
# invocation can hide that stream. Persist the dev exception for Actions.
$catchNeedle = '            Console.Error.WriteLine(ex);'
$catchNew = $catchNeedle + [Environment]::NewLine + '            try { System.IO.File.WriteAllText(System.IO.Path.Combine(System.IO.Path.GetTempPath(), "AdaptiveMedia-0.3.2-integration-error.txt"), ex.ToString()); } catch { }'
Replace-Exact $program $catchNeedle $catchNew

# ---------------------------------------------------------------------------
# Fail-closed verification.
# ---------------------------------------------------------------------------
$verifyInput = Read-Text $input
if ($verifyInput -notmatch '(?m)^ESC\s+set\s+fullscreen\s+no\s*$') { throw '0.3.2 dev ESC fullscreen binding is missing.' }
if ($verifyInput -match '(?im)^\s*ESC\s+.*\bquit(?:-watch-later)?\b') { throw '0.3.2 dev still contains an ESC quit binding.' }

$verifyEngine = Read-Text $engine
if (([regex]::Matches($verifyEngine, [regex]::Escape(".Add('--vulkan-swap-mode=fifo')"))).Count -ne 1) {
    throw 'Renderer-aware 0.3.2 must add Vulkan FIFO exactly once, after final renderer selection.'
}
if (-not $verifyEngine.Contains("`$finalUsesD3d11 = `$MpvArgs.Contains('--profile=compatibility') -or `$MpvArgs.Contains('--gpu-context=d3d11')")) {
    throw 'Renderer-aware FIFO D3D11 guard is missing.'
}
$idxVpp = $verifyEngine.IndexOf("`$MpvArgs.Add('--gpu-context=d3d11')")
$idxFifoGuard = $verifyEngine.IndexOf('$finalUsesD3d11 =')
if ($idxVpp -lt 0 -or $idxFifoGuard -le $idxVpp) { throw 'FIFO decision must occur after the RTX D3D11 override.' }
if ($verifyEngine -match '--video-sync-max-factor=12') { throw 'Invalid 0.3.0 motion max-factor 12 reappeared.' }
if (-not $verifyEngine.Contains('StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)')) { throw '0.3.2 diagnostics UTF-8 decoding is missing.' }
if ($verifyEngine.Contains('& $mpv --no-config --version')) { throw 'Diagnostics still pipes mpv version through the PowerShell console code page.' }
if (-not $verifyEngine.Contains('Graphics topology hint: ')) { throw '0.3.2 multi-adapter diagnostics hint is missing.' }

$verifyProgram = Read-Text $program
foreach ($needle in @(
    'new PlaybackOptions("Compatibility", "Off", "Smooth", false, false)',
    'Has(compatibilitySmooth, "--vulkan-swap-mode=fifo")',
    'AdaptiveMedia-0.3.2-integration-error.txt'
)) {
    if (-not $verifyProgram.Contains($needle)) { throw "0.3.2 integration gate is missing: $needle" }
}
if (([regex]::Matches($verifyProgram, [regex]::Escape('--vulkan-swap-mode=fifo'))).Count -lt 3) {
    throw '0.3.2 integration coverage must assert FIFO presence for Vulkan motion and absence for Compatibility motion.'
}

Write-Host 'Adaptive Media 0.3.2-dev2 renderer-aware motion, fullscreen, and diagnostics fixes applied and verified.'
