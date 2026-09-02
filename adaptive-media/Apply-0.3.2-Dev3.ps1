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
$backend = Join-Path $SourceRoot 'src\AdaptiveMedia.App\BackendBridge.cs'
$program = Join-Path $SourceRoot 'src\AdaptiveMedia.App\Program.cs'
$iss     = Join-Path $SourceRoot 'installer\AdaptiveMedia.iss'
$proj    = Join-Path $SourceRoot 'src\AdaptiveMedia.App\AdaptiveMedia.App.csproj'
$xaml    = Join-Path $SourceRoot 'src\AdaptiveMedia.App\MainWindow.xaml'
$readme  = Join-Path $SourceRoot 'README.md'
$mpvConf = Join-Path $SourceRoot 'payload\mpv-config\mpv.conf'
$input   = Join-Path $SourceRoot 'payload\mpv-config\input.conf'

# ---------------------------------------------------------------------------
# Integration-only media capability injection.
# ---------------------------------------------------------------------------
# PlanJson already exists solely to expose the final launch plan to the compiled
# WPF integration harness. Allow only Play-MediaHeadless/PlanJson to supply a
# fake media probe and fake NVIDIA capability through child-process environment
# variables. The earlier interactive Play-Media probe assignment is deliberately
# left untouched, so normal playback can never consume the synthetic probe.
$engineText = Read-Text $engine
$headlessProbePattern = '(?ms)(function Play-MediaHeadless \{.*?\$first = \$expanded\[0\]\r?\n)    \$probe = if \(-not \(Test-IsUrl \$first\)\) \{ Probe-Media \$mpv \$first \} else \{ \$null \}'
$headlessProbeMatches = [regex]::Matches($engineText, $headlessProbePattern)
if ($headlessProbeMatches.Count -ne 1) {
    throw "Expected exactly one Play-MediaHeadless probe assignment; found $($headlessProbeMatches.Count)."
}
$newProbeBody = @'
    $integrationProbeJson = if ($PlanJson) { [Environment]::GetEnvironmentVariable('ADAPTIVE_MEDIA_INTEGRATION_PROBE_JSON') } else { $null }
    $probe = if (-not [string]::IsNullOrWhiteSpace($integrationProbeJson)) {
        try { $integrationProbeJson | ConvertFrom-Json -ErrorAction Stop }
        catch { throw 'Adaptive Media integration probe JSON is invalid.' }
    }
    elseif (-not (Test-IsUrl $first)) { Probe-Media $mpv $first }
    else { $null }
'@
$engineText = [regex]::Replace(
    $engineText,
    $headlessProbePattern,
    { param($m) $m.Groups[1].Value + $newProbeBody },
    1
)
Write-Utf8NoBom $engine $engineText

# Add deterministic NVIDIA capability only inside PlanJson enhancement planning.
$engineText = Read-Text $engine
$nvidiaPattern = '(?m)^    \$nvidia = Test-NvidiaGpuPresent\r?$'
$nvidiaMatches = [regex]::Matches($engineText, $nvidiaPattern)
if ($nvidiaMatches.Count -ne 1) {
    throw "Expected exactly one per-video NVIDIA planning assignment; found $($nvidiaMatches.Count)."
}
$nvidiaReplacement = '    $integrationNvidia = $PlanJson -and ([Environment]::GetEnvironmentVariable(''ADAPTIVE_MEDIA_INTEGRATION_NVIDIA'') -eq ''1'')' + [Environment]::NewLine +
                     '    $nvidia = (Test-NvidiaGpuPresent) -or $integrationNvidia'
$engineText = [regex]::Replace($engineText, $nvidiaPattern, $nvidiaReplacement, 1)
Write-Utf8NoBom $engine $engineText

# ---------------------------------------------------------------------------
# Carry integration-only capability data through the real BackendBridge method.
# ---------------------------------------------------------------------------
$oldSignature = '    public async Task<PlaybackLaunchPlan> GetPlaybackPlanAsync(IReadOnlyList<string> items, PlaybackOptions options)'
$newSignature = '    public async Task<PlaybackLaunchPlan> GetPlaybackPlanAsync(IReadOnlyList<string> items, PlaybackOptions options, string? integrationProbeJson = null, bool integrationNvidia = false)'
Replace-Exact $backend $oldSignature $newSignature

$backendText = Read-Text $backend
$psiPattern = '(?m)^        var psi = NewPsi\(capture: true\);\r?\n        psi\.ArgumentList\.Add\("-Headless"\);\r?\n        psi\.ArgumentList\.Add\("-PlanJson"\);'
$psiMatches = [regex]::Matches($backendText, $psiPattern)
if ($psiMatches.Count -ne 1) {
    throw "Expected exactly one playback-plan ProcessStartInfo sequence; found $($psiMatches.Count)."
}
$psiReplacement = @'
        var psi = NewPsi(capture: true);
        if (!string.IsNullOrWhiteSpace(integrationProbeJson))
            psi.Environment["ADAPTIVE_MEDIA_INTEGRATION_PROBE_JSON"] = integrationProbeJson;
        if (integrationNvidia)
            psi.Environment["ADAPTIVE_MEDIA_INTEGRATION_NVIDIA"] = "1";
        psi.ArgumentList.Add("-Headless");
        psi.ArgumentList.Add("-PlanJson");
'@
$backendText = [regex]::Replace($backendText, $psiPattern, $psiReplacement, 1)
Write-Utf8NoBom $backend $backendText

# ---------------------------------------------------------------------------
# Exercise RTX VSR + RTX Video HDR through WPF -> BackendBridge -> engine.
# ---------------------------------------------------------------------------
$compatMarker = '            var compatibilitySmooth = await backend.GetPlaybackPlanAsync('
$rtxTest = @'
            const string syntheticSdr1080Probe = "{\"Width\":1920,\"Height\":1080,\"Fps\":24.0,\"VideoCodec\":\"h264\",\"Gamma\":\"bt.1886\",\"Primaries\":\"bt.709\",\"AudioCodec\":\"aac\",\"HdrFamily\":false}";
            var rtx = await backend.GetPlaybackPlanAsync(
                syntheticUrl,
                new PlaybackOptions("Enhanced", "RtxVsr", "Smooth", false, true),
                syntheticSdr1080Probe,
                integrationNvidia: true);
            if (!Has(rtx, "--gpu-api=d3d11") ||
                !Has(rtx, "--gpu-context=d3d11") ||
                !Has(rtx, "--hwdec=d3d11va,auto") ||
                Has(rtx, "--vulkan-swap-mode=fifo") ||
                !rtx.Arguments.Any(a => a.StartsWith("--vf=d3d11vpp=", StringComparison.OrdinalIgnoreCase) &&
                                        a.Contains("scale=2.0", StringComparison.OrdinalIgnoreCase) &&
                                        a.Contains("scaling-mode=nvidia", StringComparison.OrdinalIgnoreCase) &&
                                        a.Contains("nvidia-true-hdr=yes", StringComparison.OrdinalIgnoreCase)))
                return 26;

'@
Replace-Exact $program $compatMarker ($rtxTest + $compatMarker)

# ---------------------------------------------------------------------------
# Internal dev3 metadata only; no public release/tag.
# ---------------------------------------------------------------------------
Replace-Exact $iss  '#define MyAppVersion "0.3.2-dev2"' '#define MyAppVersion "0.3.2-dev3"'
Replace-Exact $proj '<InformationalVersion>0.3.2-dev2</InformationalVersion>' '<InformationalVersion>0.3.2-dev3</InformationalVersion>'
Replace-Exact $xaml 'Text="v0.3.2-dev2"' 'Text="v0.3.2-dev3"'
Replace-Exact $readme '# Adaptive Media 0.3.2-dev2' '# Adaptive Media 0.3.2-dev3'
Replace-Exact $readme 'AdaptiveMediaSetup-0.3.2-dev2-x64.exe' 'AdaptiveMediaSetup-0.3.2-dev3-x64.exe'
Replace-Exact $mpvConf '# Adaptive Media 0.3.2-dev2 - managed mpv defaults' '# Adaptive Media 0.3.2-dev3 - managed mpv defaults'
Replace-Exact $input '# Adaptive Media 0.3.2-dev2' '# Adaptive Media 0.3.2-dev3'

# ---------------------------------------------------------------------------
# Fail-closed verification.
# ---------------------------------------------------------------------------
$verifyEngine = Read-Text $engine
foreach ($needle in @(
    'ADAPTIVE_MEDIA_INTEGRATION_PROBE_JSON',
    'ADAPTIVE_MEDIA_INTEGRATION_NVIDIA',
    '$integrationNvidia = $PlanJson -and',
    ".Add('--gpu-api=d3d11')",
    ".Add('--gpu-context=d3d11')",
    ".Add('--vulkan-swap-mode=fifo')"
)) {
    if (-not $verifyEngine.Contains($needle)) { throw "Engine integration coverage seam missing: $needle" }
}
if (([regex]::Matches($verifyEngine, 'ADAPTIVE_MEDIA_INTEGRATION_PROBE_JSON')).Count -ne 1) { throw 'Integration probe environment hook duplicated.' }
if (([regex]::Matches($verifyEngine, 'ADAPTIVE_MEDIA_INTEGRATION_NVIDIA')).Count -ne 1) { throw 'Integration NVIDIA environment hook duplicated.' }
if (([regex]::Matches($verifyEngine, [regex]::Escape('    $probe = if (-not (Test-IsUrl $first)) { Probe-Media $mpv $first } else { $null }'))).Count -ne 1) {
    throw 'Interactive Play-Media probe assignment was changed; integration injection must remain headless-only.'
}
$headlessIndex = $verifyEngine.IndexOf('function Play-MediaHeadless {')
$integrationProbeIndex = $verifyEngine.IndexOf('ADAPTIVE_MEDIA_INTEGRATION_PROBE_JSON')
if ($headlessIndex -lt 0 -or $integrationProbeIndex -le $headlessIndex) { throw 'Synthetic probe hook is not scoped inside Play-MediaHeadless.' }

$verifyBackend = Read-Text $backend
if (-not $verifyBackend.Contains('string? integrationProbeJson = null, bool integrationNvidia = false')) { throw 'BackendBridge integration-only optional arguments missing.' }
if (([regex]::Matches($verifyBackend, 'ADAPTIVE_MEDIA_INTEGRATION_PROBE_JSON')).Count -ne 1) { throw 'BackendBridge probe environment assignment missing or duplicated.' }
if (([regex]::Matches($verifyBackend, 'ADAPTIVE_MEDIA_INTEGRATION_NVIDIA')).Count -ne 1) { throw 'BackendBridge NVIDIA environment assignment missing or duplicated.' }

$verifyProgram = Read-Text $program
foreach ($needle in @(
    'syntheticSdr1080Probe',
    'new PlaybackOptions("Enhanced", "RtxVsr", "Smooth", false, true)',
    'integrationNvidia: true',
    '!Has(rtx, "--gpu-api=d3d11")',
    '!Has(rtx, "--gpu-context=d3d11")',
    'Has(rtx, "--vulkan-swap-mode=fifo")',
    'scaling-mode=nvidia',
    'nvidia-true-hdr=yes',
    'return 26;'
)) {
    if (-not $verifyProgram.Contains($needle)) { throw "RTX runtime-plan integration assertion missing: $needle" }
}

Write-Host 'Adaptive Media 0.3.2-dev3 deterministic RTX launch-plan integration coverage applied and verified.'
