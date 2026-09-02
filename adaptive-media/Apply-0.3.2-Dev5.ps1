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
$program = Join-Path $SourceRoot 'src\AdaptiveMedia.App\Program.cs'
$iss     = Join-Path $SourceRoot 'installer\AdaptiveMedia.iss'
$proj    = Join-Path $SourceRoot 'src\AdaptiveMedia.App\AdaptiveMedia.App.csproj'
$xaml    = Join-Path $SourceRoot 'src\AdaptiveMedia.App\MainWindow.xaml'
$readme  = Join-Path $SourceRoot 'README.md'
$conf    = Join-Path $SourceRoot 'payload\mpv-config\mpv.conf'
$input   = Join-Path $SourceRoot 'payload\mpv-config\input.conf'

# ---------------------------------------------------------------------------
# Defect fixed by this candidate
#
# Both NVIDIA profile decisions were written as:
#
#     if (Test-NvidiaGpuPresent -and $profile -ne 'compatibility') { ... }
#
# Inside an if() condition PowerShell parses a leading bare command name in
# command mode, so this calls Test-NvidiaGpuPresent with the literal arguments
# '-and', $profile, '-ne', 'compatibility'. The function declares no param()
# block, so those arguments land in $args and are discarded, and only the
# function's own $true/$false result is evaluated. The Compatibility exclusion
# was therefore a silent no-op on every NVIDIA machine.
#
# Consequence, measured on RTX 4080 Laptop hardware with mpv IPC:
#   --profile=compatibility --profile=nvidia  ->  gpu-api=vulkan, gpu-context=winvk,
#                                                 hwdec=nvdec
#   --profile=compatibility                   ->  gpu-api=d3d11,  gpu-context=d3d11,
#                                                 hwdec=d3d11va-copy
#
# mpv applies profiles in order, so the managed [nvidia] profile overrode the
# [compatibility] profile's explicit D3D11 renderer. The documented D3D11
# escape hatch did not actually exist on the hardware that most needs it.
#
# GitHub's windows-latest runners have no NVIDIA GPU, so Test-NvidiaGpuPresent
# returns $false there and the broken guard is invisible to CI. This candidate
# therefore also routes the existing ADAPTIVE_MEDIA_INTEGRATION_NVIDIA hook into
# the profile decision so the failure class has deterministic CI coverage.
# ---------------------------------------------------------------------------

# Headless/backend path (BackendBridge.PlayAsync and -PlanJson both land here).
# Replaced first because its single-line form also contains the shorter needle
# used for the interactive path below.
$headlessOld = "    if (Test-NvidiaGpuPresent -and `$profile -ne 'compatibility') { `$mpvArgs.Add('--profile=nvidia') }"
$headlessNew = @"
    `$integrationNvidiaProfile = `$PlanJson -and ([Environment]::GetEnvironmentVariable('ADAPTIVE_MEDIA_INTEGRATION_NVIDIA') -eq '1')
    if (((Test-NvidiaGpuPresent) -or `$integrationNvidiaProfile) -and `$profile -ne 'compatibility') { `$mpvArgs.Add('--profile=nvidia') }
"@
Replace-Exact $engine $headlessOld $headlessNew.TrimEnd("`r","`n")

# Interactive path.
$interactiveOld = "if (Test-NvidiaGpuPresent -and `$profile -ne 'compatibility') {"
$interactiveNew = "if ((Test-NvidiaGpuPresent) -and `$profile -ne 'compatibility') {"
Replace-Exact $engine $interactiveOld $interactiveNew

# Deterministic regression coverage for the exact failure class.
#   27 - Compatibility must keep its D3D11 escape hatch on NVIDIA hardware.
#   28 - proves the simulated-NVIDIA hook actually reaches the profile decision,
#        so check 27 cannot pass vacuously.
$coverageOld = '                return 23;'
$coverageNew = @'
                return 23;

            var compatibilityOnNvidia = await backend.GetPlaybackPlanAsync(
                syntheticUrl, new PlaybackOptions("Compatibility", "Off", "Smooth", false, false),
                integrationNvidia: true);
            if (!Has(compatibilityOnNvidia, "--profile=compatibility") ||
                Has(compatibilityOnNvidia, "--profile=nvidia") ||
                Has(compatibilityOnNvidia, "--vulkan-swap-mode=fifo"))
                return 27;

            var enhancedOnNvidia = await backend.GetPlaybackPlanAsync(
                syntheticUrl, new PlaybackOptions("Enhanced", "Off", "Off", false, false),
                integrationNvidia: true);
            if (!Has(enhancedOnNvidia, "--profile=nvidia"))
                return 28;
'@
Replace-Exact $program $coverageOld $coverageNew

# Internal packaging revision. Playback semantics change only by the proven
# Compatibility renderer fix above.
Replace-Exact $iss    '#define MyAppVersion "0.3.2-dev4"' '#define MyAppVersion "0.3.2-dev5"'
Replace-Exact $proj   '<InformationalVersion>0.3.2-dev4</InformationalVersion>' '<InformationalVersion>0.3.2-dev5</InformationalVersion>'
Replace-Exact $xaml   'Text="v0.3.2-dev4"' 'Text="v0.3.2-dev5"'
Replace-Exact $readme '# Adaptive Media 0.3.2-dev4' '# Adaptive Media 0.3.2-dev5'
Replace-Exact $readme 'AdaptiveMediaSetup-0.3.2-dev4-x64.exe' 'AdaptiveMediaSetup-0.3.2-dev5-x64.exe'
Replace-Exact $conf   '# Adaptive Media 0.3.2-dev4 - managed mpv defaults' '# Adaptive Media 0.3.2-dev5 - managed mpv defaults'
Replace-Exact $input  '# Adaptive Media 0.3.2-dev4' '# Adaptive Media 0.3.2-dev5'

# Fail closed if the candidate no longer contains exactly the intended plumbing.
$engineText = Read-Text $engine
if (([regex]::Matches($engineText, [regex]::Escape("if (Test-NvidiaGpuPresent -and"))).Count -ne 0) {
    throw 'A command-mode NVIDIA guard remains in the engine.'
}
if (([regex]::Matches($engineText, [regex]::Escape("if ((Test-NvidiaGpuPresent) -and `$profile -ne 'compatibility') {"))).Count -ne 1) {
    throw 'Interactive NVIDIA profile guard missing or duplicated.'
}
if (([regex]::Matches($engineText, [regex]::Escape("if (((Test-NvidiaGpuPresent) -or `$integrationNvidiaProfile) -and `$profile -ne 'compatibility')"))).Count -ne 1) {
    throw 'Headless NVIDIA profile guard missing or duplicated.'
}
if (([regex]::Matches($engineText, [regex]::Escape('$integrationNvidiaProfile = $PlanJson -and'))).Count -ne 1) {
    throw 'Headless simulated-NVIDIA plumbing missing or duplicated.'
}
if (([regex]::Matches($engineText, 'ADAPTIVE_MEDIA_INTEGRATION_NVIDIA')).Count -ne 2) {
    throw 'Expected exactly two ADAPTIVE_MEDIA_INTEGRATION_NVIDIA sites in the engine.'
}
# The renderer decisions this candidate must not disturb.
if (([regex]::Matches($engineText, [regex]::Escape(".Add('--vulkan-swap-mode=fifo')"))).Count -ne 1) { throw 'FIFO must still be added once at final renderer decision.' }
if (([regex]::Matches($engineText, [regex]::Escape(".Add('--gpu-api=d3d11')"))).Count -ne 1) { throw 'RTX VPP gpu-api=d3d11 override missing or duplicated.' }
if (([regex]::Matches($engineText, [regex]::Escape(".Add('--gpu-context=d3d11')"))).Count -ne 1) { throw 'RTX VPP gpu-context=d3d11 override missing or duplicated.' }

$programText = Read-Text $program
foreach ($needle in @(
    'compatibilityOnNvidia',
    'enhancedOnNvidia',
    'return 27;',
    'return 28;',
    'new PlaybackOptions("Compatibility", "Off", "Smooth", false, false),'
)) {
    if (-not $programText.Contains($needle)) { throw "Compatibility renderer regression coverage missing: $needle" }
}
if (([regex]::Matches($programText, [regex]::Escape('integrationNvidia: true'))).Count -ne 3) {
    throw 'Expected exactly three simulated-NVIDIA integration plans (RTX, Compatibility, Enhanced).'
}

$issText = Read-Text $iss
if (-not $issText.Contains('#define MyAppVersion "0.3.2-dev5"')) { throw 'Dev5 installer version missing.' }

Write-Host 'Adaptive Media 0.3.2-dev5 Compatibility renderer fix and deterministic NVIDIA-profile regression coverage applied and verified.'
