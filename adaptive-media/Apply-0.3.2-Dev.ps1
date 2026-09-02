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
# 0.3.2 dev: renderer-aware display-sync presentation and RTX D3D11 pairing.
# ---------------------------------------------------------------------------
# mpv requires a vsync-blocked Vulkan swapchain for display-* sync. The managed
# default is Vulkan and the NVIDIA profile is explicit winvk. Compatibility is
# explicit D3D11, while RTX VSR/HDR invokes d3d11vpp and therefore must switch
# BOTH gpu-api and gpu-context to D3D11. Decide FIFO only after those overrides.
$engineText = Read-Text $engine
$displayAddPattern = '(?m)^\s*\$MpvArgs\.Add\(''--video-sync=display-resample''\)\s*$'
if (([regex]::Matches($engineText, $displayAddPattern)).Count -ne 2) {
    throw 'Expected exactly two display-resample motion lanes after 0.3.1.'
}

$vppPattern = '(?ms)^    if \(\$vpp\.Count -gt 0\) \{\r?\n        # d3d11vpp is intentionally an opt-in path because the validated reference\r?\n        # path on hybrid NVIDIA laptops is winvk \+ NVDEC\. RTX VSR/HDR require D3D11 VPP\.\r?\n        \$MpvArgs\.Add\(''--gpu-context=d3d11''\)\r?\n        \$MpvArgs\.Add\(''--hwdec=d3d11va,auto''\)\r?\n        \$MpvArgs\.Add\(''--vf=d3d11vpp='' \+ \(\$vpp -join '':''\)\)\r?\n    \}\r?\n(?=\})'
$vppMatches = [regex]::Matches($engineText, $vppPattern)
if ($vppMatches.Count -ne 1) {
    throw "Expected one bounded RTX d3d11vpp tail; found $($vppMatches.Count)."
}
$vppReplacement = @'
    if ($vpp.Count -gt 0) {
        # d3d11vpp is intentionally an opt-in path because the validated reference
        # path on hybrid NVIDIA laptops is winvk + NVDEC. RTX VSR/HDR require D3D11 VPP.
        # Pair API and context explicitly so inherited Vulkan settings cannot conflict.
        $MpvArgs.Add('--gpu-api=d3d11')
        $MpvArgs.Add('--gpu-context=d3d11')
        $MpvArgs.Add('--hwdec=d3d11va,auto')
        $MpvArgs.Add('--vf=d3d11vpp=' + ($vpp -join ':'))
    }

    # Decide presentation only after every optional renderer override is known.
    $motionUsesDisplaySync = ($Motion -eq 'Gentle' -or $Motion -eq 'Smooth')
    $finalUsesD3d11 = $MpvArgs.Contains('--profile=compatibility') -or $MpvArgs.Contains('--gpu-api=d3d11') -or $MpvArgs.Contains('--gpu-context=d3d11')
    if ($motionUsesDisplaySync -and -not $finalUsesD3d11) {
        $MpvArgs.Add('--vulkan-swap-mode=fifo')
    }
'@
$engineText = [regex]::Replace($engineText, $vppPattern, $vppReplacement, 1)
Write-Utf8NoBom $engine $engineText

# Correct a stale source comment from the older auto-backend design.
$engineText = Read-Text $engine
$oldNvidiaCommentPattern = '(?m)^    # NVIDIA policy is capability-based, not model-specific\. Prefer NVDEC while\r?\n    # leaving gpu-next''s Windows graphics backend on auto so Optimus/MUX/Advanced\r?\n    # Optimus and externally wired displays can use the path that actually works\.$'
$newNvidiaComment = @'
    # NVIDIA policy is capability-based, not model-specific. The managed NVIDIA
    # profile selects the validated winvk + NVDEC path; Compatibility remains the
    # explicit D3D11 escape hatch for systems where that path is unsuitable.
'@
if (([regex]::Matches($engineText, $oldNvidiaCommentPattern)).Count -eq 1) {
    $engineText = [regex]::Replace($engineText, $oldNvidiaCommentPattern, $newNvidiaComment, 1)
    Write-Utf8NoBom $engine $engineText
}

# ---------------------------------------------------------------------------
# 0.3.2 dev: decode native UTF-8 tool output explicitly in diagnostics.
# ---------------------------------------------------------------------------
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

$oldPolicy = '    $lines.Add(''Playback policy: reference sync=audio; NVIDIA present='' + (Test-NvidiaGpuPresent) + ''; NVIDIA context priority=winvk,d3d11; decoder priority=nvdec,d3d11va,auto'')'
$newPolicy = '    $lines.Add(''Playback policy: reference sync=audio; NVIDIA present='' + (Test-NvidiaGpuPresent) + ''; NVIDIA=winvk + nvdec,auto-safe; Compatibility=d3d11 + d3d11va-copy,auto-safe; RTX VPP=d3d11 API/context'')'
Replace-Exact $engine $oldPolicy $newPolicy

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
if (([regex]::Matches($verifyEngine, [regex]::Escape(".Add('--vulkan-swap-mode=fifo')"))).Count -ne 1) { throw 'Renderer-aware FIFO must have exactly one final add site.' }
if (([regex]::Matches($verifyEngine, [regex]::Escape(".Add('--gpu-api=d3d11')"))).Count -ne 1) { throw 'RTX VPP must explicitly override gpu-api to d3d11 exactly once.' }
if (([regex]::Matches($verifyEngine, [regex]::Escape(".Add('--gpu-context=d3d11')"))).Count -ne 1) { throw 'RTX VPP must explicitly override gpu-context to d3d11 exactly once.' }
if (-not $verifyEngine.Contains("`$finalUsesD3d11 = `$MpvArgs.Contains('--profile=compatibility') -or `$MpvArgs.Contains('--gpu-api=d3d11') -or `$MpvArgs.Contains('--gpu-context=d3d11')")) { throw 'Renderer-aware D3D11 FIFO guard is missing.' }
$idxApi = $verifyEngine.IndexOf("`$MpvArgs.Add('--gpu-api=d3d11')")
$idxContext = $verifyEngine.IndexOf("`$MpvArgs.Add('--gpu-context=d3d11')")
$idxFifoGuard = $verifyEngine.IndexOf('$finalUsesD3d11 =')
if ($idxApi -lt 0 -or $idxContext -le $idxApi -or $idxFifoGuard -le $idxContext) { throw 'RTX D3D11 API/context and FIFO-decision ordering is invalid.' }
if ($verifyEngine -match '--video-sync-max-factor=12') { throw 'Invalid 0.3.0 motion max-factor 12 reappeared.' }
if (-not $verifyEngine.Contains('StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)')) { throw '0.3.2 diagnostics UTF-8 decoding is missing.' }
if ($verifyEngine.Contains('& $mpv --no-config --version')) { throw 'Diagnostics still pipes mpv version through the PowerShell console code page.' }
if (-not $verifyEngine.Contains('Graphics topology hint: ')) { throw '0.3.2 multi-adapter diagnostics hint is missing.' }
if ($verifyEngine.Contains('NVIDIA context priority=winvk,d3d11')) { throw 'Stale diagnostics still claims a nonexistent NVIDIA context fallback.' }

$verifyProgram = Read-Text $program
foreach ($needle in @(
    'new PlaybackOptions("Compatibility", "Off", "Smooth", false, false)',
    'Has(compatibilitySmooth, "--vulkan-swap-mode=fifo")',
    'AdaptiveMedia-0.3.2-integration-error.txt'
)) {
    if (-not $verifyProgram.Contains($needle)) { throw "0.3.2 integration gate is missing: $needle" }
}
if (([regex]::Matches($verifyProgram, [regex]::Escape('--vulkan-swap-mode=fifo'))).Count -lt 3) { throw 'Integration coverage must assert FIFO presence for Vulkan motion and absence for Compatibility motion.' }

Write-Host 'Adaptive Media 0.3.2-dev2 renderer-aware motion, RTX D3D11 pairing, fullscreen, and diagnostics fixes applied and verified.'
