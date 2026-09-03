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

# ---------------------------------------------------------------------------
# Final 0.3.2 consumer candidate.
#
# No behaviour changes over 0.3.2-dev7, which passed the objective hardware gate
# on the RTX 4080 Laptop validation machine. This patch only turns the private
# hardware candidate into the shipping build:
#
#   - user-visible version metadata carries no dev or RC label
#   - an ordinary install no longer offers to run certification as its default
#     post-install action; the launcher does
#   - the bundled certification script keeps shipping, renamed in the Start menu
#     to read as the support and diagnostics tool it is for end users
# ---------------------------------------------------------------------------

# Shipping version metadata.
Replace-Exact $iss    '#define MyAppVersion "0.3.2-dev7"' '#define MyAppVersion "0.3.2"'
Replace-Exact $proj   '<InformationalVersion>0.3.2-dev7</InformationalVersion>' '<InformationalVersion>0.3.2</InformationalVersion>'
Replace-Exact $xaml   'Text="v0.3.2-dev7"' 'Text="v0.3.2"'
Replace-Exact $readme '# Adaptive Media 0.3.2-dev7' '# Adaptive Media 0.3.2'
Replace-Exact $readme 'AdaptiveMediaSetup-0.3.2-dev7-x64.exe' 'AdaptiveMediaSetup-0.3.2-x64.exe'
Replace-Exact $conf   '# Adaptive Media 0.3.2-dev7 - managed mpv defaults' '# Adaptive Media 0.3.2 - managed mpv defaults'
Replace-Exact $input  '# Adaptive Media 0.3.2-dev7' '# Adaptive Media 0.3.2'

# The shipped config should point a curious user at the release notes, not at an
# internal patch script that is not part of the installed product.
Replace-Exact $conf `
    '# Automatic motion fallback - see Apply-0.3.2-Dev7.ps1 for the measurements.' `
    '# Automatic motion fallback - see the Adaptive Media 0.3.2 release notes.'

# A consumer install must not run the certification harness. Launching the
# player becomes the single, default post-install action instead. Both lines are
# replaced together so no blank line is left behind in the [Run] section.
$issText = Read-Text $iss
$nl = if ($issText.Contains("`r`n")) { "`r`n" } else { "`n" }
$runOld = 'Filename: "{app}\certification\Test-0.3.2-Hardware.cmd"; Description: "Run objective 0.3.2 hardware certification"; Flags: nowait postinstall skipifsilent' +
          $nl +
          'Filename: "{app}\{#MyAppExeName}"; Description: "Launch Adaptive Media"; Flags: nowait postinstall skipifsilent unchecked'
$runNew = 'Filename: "{app}\{#MyAppExeName}"; Description: "Launch Adaptive Media"; Flags: nowait postinstall skipifsilent'
Replace-Exact $iss $runOld $runNew

# The harness still ships, named for what it does for a user who needs support.
Replace-Exact $iss `
    'Name: "{group}\Adaptive Media 0.3.2 Hardware Certification"; Filename: "{app}\certification\Test-0.3.2-Hardware.cmd"; WorkingDir: "{app}\certification"; Tasks: startmenu' `
    'Name: "{group}\Adaptive Media Playback Diagnostics"; Filename: "{app}\certification\Test-0.3.2-Hardware.cmd"; WorkingDir: "{app}\certification"; Tasks: startmenu'

# --- fail closed -----------------------------------------------------------
$issText = Read-Text $iss
if (-not $issText.Contains('#define MyAppVersion "0.3.2"')) { throw 'Final installer version missing.' }
if ($issText -match '(?i)0\.3\.2-(dev|rc)') { throw 'A dev or RC label survives in the installer definition.' }
if ($issText.Contains('Run objective 0.3.2 hardware certification')) { throw 'A consumer install still offers to run hardware certification.' }
$runLines = @([regex]::Matches($issText, '(?m)^Filename:.*postinstall.*$') | ForEach-Object { $_.Value })
if ($runLines.Count -ne 1) { throw "Expected exactly one post-install action, found $($runLines.Count)." }
if ($runLines[0] -notmatch 'MyAppExeName') { throw 'The single post-install action must be launching Adaptive Media.' }
if ($runLines[0] -match 'certification') { throw 'The post-install action must not be the certification harness.' }
if (-not $issText.Contains('Name: "{group}\Adaptive Media Playback Diagnostics"')) { throw 'Diagnostics Start Menu entry missing.' }
if ($issText.Contains('Adaptive Media 0.3.2 Hardware Certification')) { throw 'The developer-facing certification shortcut name survives.' }
# The harness itself must still be installed for support use.
if (-not $issText.Contains('certification\Test-0.3.2-Hardware.cmd')) { throw 'The bundled diagnostics harness is no longer installed.' }

foreach ($pair in @(
    @{ Path=$proj;   Needle='<InformationalVersion>0.3.2</InformationalVersion>' },
    @{ Path=$xaml;   Needle='Text="v0.3.2"' },
    @{ Path=$readme; Needle='# Adaptive Media 0.3.2' },
    @{ Path=$conf;   Needle='# Adaptive Media 0.3.2 - managed mpv defaults' },
    @{ Path=$input;  Needle='# Adaptive Media 0.3.2' }
)) {
    if (-not (Read-Text $pair.Path).Contains($pair.Needle)) { throw "Final version metadata missing in $($pair.Path)" }
}
foreach ($path in @($proj, $xaml, $readme, $conf, $input)) {
    if ((Read-Text $path) -match '(?i)0\.3\.2-(dev|rc)') { throw "A dev or RC label survives in $path" }
}
$projText = Read-Text $proj
foreach ($needle in @('<FileVersion>0.3.2.0</FileVersion>', '<AssemblyVersion>0.3.2.0</AssemblyVersion>')) {
    if (-not $projText.Contains($needle)) { throw "Final assembly version metadata missing: $needle" }
}

# Everything dev7 proved on hardware must survive into the shipping build.
$confText = Read-Text $conf
if (-not $confText.Contains('[motion-guard]')) { throw 'The automatic motion fallback did not survive into the final build.' }
if (-not $confText.Contains('profile-cond=(p.time_pos or 0) > 5 and (p.vsync_jitter or 0) > 0.1 and (p.vo_delayed_frame_count or 0) > 2 * (p.time_pos or 1)')) {
    throw 'The motion guard condition is not the reviewed, measured one.'
}
if ($confText -notmatch '(?ms)^\[compatibility\].*?gpu-api=d3d11.*?gpu-context=d3d11') { throw 'Compatibility profile is no longer explicitly D3D11.' }
if ($confText -notmatch '(?ms)^\[nvidia\].*?gpu-api=vulkan.*?gpu-context=winvk') { throw 'NVIDIA profile is no longer explicitly Vulkan/winvk.' }
$engineText = Read-Text (Join-Path $SourceRoot 'payload\AdaptiveMedia.Engine.ps1')
if ($engineText -match [regex]::Escape('if (Test-NvidiaGpuPresent -and')) { throw 'The command-mode NVIDIA guard returned; the Compatibility escape hatch would be inoperative.' }
if ($engineText.Contains('--profile=motion-guard')) { throw 'The engine must not request the motion guard explicitly.' }

Write-Host 'Adaptive Media 0.3.2 final consumer candidate applied and verified.'
