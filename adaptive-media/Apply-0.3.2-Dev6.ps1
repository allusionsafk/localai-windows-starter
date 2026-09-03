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

$iss    = Join-Path $SourceRoot 'installer\AdaptiveMedia.iss'
$proj   = Join-Path $SourceRoot 'src\AdaptiveMedia.App\AdaptiveMedia.App.csproj'
$xaml   = Join-Path $SourceRoot 'src\AdaptiveMedia.App\MainWindow.xaml'
$readme = Join-Path $SourceRoot 'README.md'
$conf   = Join-Path $SourceRoot 'payload\mpv-config\mpv.conf'
$input  = Join-Path $SourceRoot 'payload\mpv-config\input.conf'
$cert   = Join-Path $SourceRoot 'payload\certification\Test-0.3.2-Hardware.ps1'

# ---------------------------------------------------------------------------
# Candidate scope
#
# dev6 changes no product behaviour. It exists so the two certification-
# instrument defects found by the first successful real-hardware run of the
# dev5 gate ship inside a single, traceable private installer:
#
#   1. Collapsed launch vector. Start-PlannedMpv built its injected mpv options
#      as @( '--input-ipc-server=' + $PipePath, '--terminal=no', ... ). The comma
#      operator binds tighter than '+' in PowerShell, so that parses as
#      @( '--input-ipc-server=' + @($PipePath, '--terminal=no', ...) ) and
#      collapses all five options into ONE space-joined argument. mpv created a
#      pipe whose literal name contained the whole string, --terminal, --mute and
#      --loop-file were never applied, and the gate timed out connecting to the
#      pipe it had asked for. Observed as:
#        Exception calling "Connect" with "1" argument(s): "The operation has timed out."
#
#   2. Structured option values. mpv returns options/gpu-api and
#      options/gpu-context over JSON IPC as {"name":"vulkan","enabled":true,
#      "params":{}}, not as plain strings. The gate compared them with [string]
#      and failed a correctly configured managed NVIDIA renderer with:
#        Effective NVIDIA gpu-api is '@{name=vulkan; enabled=True; params=}', expected vulkan.
#
# Both fixes live in the reviewed repository copy of Test-0.3.2-Hardware.ps1,
# which Apply-0.3.2-Dev4.ps1 copies into payload\certification and hash-verifies
# against the repository original. The product launch plan is untouched: the
# recorded LaunchPlan from the failing dev5 run was already correct.
# ---------------------------------------------------------------------------

Replace-Exact $iss    '#define MyAppVersion "0.3.2-dev5"' '#define MyAppVersion "0.3.2-dev6"'
Replace-Exact $proj   '<InformationalVersion>0.3.2-dev5</InformationalVersion>' '<InformationalVersion>0.3.2-dev6</InformationalVersion>'
Replace-Exact $xaml   'Text="v0.3.2-dev5"' 'Text="v0.3.2-dev6"'
Replace-Exact $readme '# Adaptive Media 0.3.2-dev5' '# Adaptive Media 0.3.2-dev6'
Replace-Exact $readme 'AdaptiveMediaSetup-0.3.2-dev5-x64.exe' 'AdaptiveMediaSetup-0.3.2-dev6-x64.exe'
Replace-Exact $conf   '# Adaptive Media 0.3.2-dev5 - managed mpv defaults' '# Adaptive Media 0.3.2-dev6 - managed mpv defaults'
Replace-Exact $input  '# Adaptive Media 0.3.2-dev5' '# Adaptive Media 0.3.2-dev6'

# Fail closed if the bundled certification gate is not the repaired instrument.
$certText = Read-Text $cert
foreach ($needle in @(
    'function Get-PlannedMpvArguments',
    "('--input-ipc-server=' + `$PipePath),",
    'function ConvertTo-OptionText',
    'Planned mpv launch vector has {0} argument(s)',
    'Launch vector did not survive command-line quoting',
    'mpv option normalisation returned'
)) {
    if (-not $certText.Contains($needle)) { throw "Repaired hardware gate is missing required content: $needle" }
}
if ($certText.Contains("        '--input-ipc-server=' + `$PipePath,")) {
    throw 'The collapsed certification launch vector has returned to the hardware gate.'
}
foreach ($stale in @(
    "[string]`$api.Value -ne 'vulkan'",
    "[string]`$context.Value -ne 'winvk'",
    "[string]`$swap.Value -ne 'fifo'"
)) {
    if ($certText.Contains($stale)) { throw "The hardware gate still string-compares a structured mpv option value: $stale" }
}
if (([regex]::Matches($certText, [regex]::Escape('[AdaptiveMediaHardwareNative]::Join($arguments)'))).Count -ne 1) {
    throw 'Start-PlannedMpv no longer joins a single strongly typed argument vector.'
}

$issText = Read-Text $iss
if (-not $issText.Contains('#define MyAppVersion "0.3.2-dev6"')) { throw 'Dev6 installer version missing.' }

Write-Host 'Adaptive Media 0.3.2-dev6 repaired hardware-certification instrument packaged and verified.'
