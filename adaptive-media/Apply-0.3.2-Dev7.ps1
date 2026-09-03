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
# Automatic motion fallback for displays that cannot present at a stable rate.
#
# mpv's display-synchronised modes, which Gentle and Smooth motion both use,
# require the display to actually present at a stable and known refresh rate.
# The RTX 4080 Laptop validation machine's 240 Hz BOE NE160QDM-NZ8 panel does
# not. Measured over a 25 s window on a 4K HEVC Dolby Vision/HDR sample with the
# machine otherwise idle and mpv confirmed running on the NVIDIA GPU:
#
#   estimated-display-fps  wanders 120 - 231 against a nominal 240
#   vsync-jitter           0.21 - 1.01, where a healthy display sits near 0.01
#   vo-delayed-frame-count climbs continuously to 273
#   frame-drop-count       climbs continuously to 38
#
# This is not caused by Adaptive Media's configuration. Stock mpv with
# --no-config and the same display-sync options is worse on the same machine
# (179 delayed and 12 output drops against 155 and 5), and every Adaptive Media
# path that does not use display synchronisation - Reference, Enhanced, and
# Smooth forced to --video-sync=audio - measures a clean 0 delayed and 0 drops.
#
# Rather than present visibly broken interpolated playback, mpv now falls back
# to native cadence by itself when the display proves it cannot sustain display
# synchronisation. Measured effect of the guard on the same machine and sample:
#
#   Smooth motion without the guard   drops climb continuously (38 in 25 s)
#   Smooth motion with the guard      falls back at ~6 s, then 0 further drops
#
# The condition requires all three of: the playback has had five seconds to
# settle, the display is measurably unstable, and it is measurably harming
# playback. A healthy display that is merely slow to converge its vsync estimate
# therefore cannot trigger it, which was verified with an unsatisfiable
# condition leaving display synchronisation active for a full run.
#
# There is deliberately no profile-restore. Restoring display synchronisation
# once the delayed-frame rate fell back below the threshold would immediately
# re-break playback and oscillate, so the fallback is sticky for the file.
# ---------------------------------------------------------------------------

$guard = @'

# Automatic motion fallback - see Apply-0.3.2-Dev7.ps1 for the measurements.
# Applied by mpv automatically as a conditional auto profile; it must not be
# requested with --profile, which would apply it unconditionally.
[motion-guard]
profile-desc=Fall back from display-synchronised motion when the display cannot present at a stable rate
profile-cond=(p.time_pos or 0) > 5 and (p.vsync_jitter or 0) > 0.1 and (p.vo_delayed_frame_count or 0) > 2 * (p.time_pos or 1)
video-sync=audio
interpolation=no
'@

$confText = Read-Text $conf
if ($confText.Contains('[motion-guard]')) { throw 'The motion guard profile is already present in mpv.conf.' }
if (-not $confText.Contains('[enhanced]')) { throw 'mpv.conf does not contain the expected managed profiles.' }
Write-Utf8NoBom $conf ($confText.TrimEnd("`r","`n") + "`r`n" + ($guard -replace "`r?`n", "`r`n"))

# Honest user-facing documentation of the new behaviour.
$readmeOld = '## Known hardware-dependent items'
$readmeNew = @'
## Automatic motion fallback

Gentle and Smooth motion use mpv's display-synchronised interpolation, which
requires the display to present at a stable, known refresh rate. Some displays,
notably laptop panels running a variable refresh rate, do not. Adaptive Media
measures this during playback and falls back to native cadence automatically
when the display is both measurably unstable and measurably dropping frames,
rather than showing broken interpolated playback. The fallback needs all three
of a five-second settling window, an unstable vsync estimate, and a sustained
delayed-frame rate, so a healthy display cannot trigger it. Reference and
Enhanced playback without motion smoothing never use display synchronisation
and are unaffected.

## Known hardware-dependent items
'@
Replace-Exact $readme $readmeOld ($readmeNew -replace "`r?`n", "`r`n")

# Internal packaging revision.
Replace-Exact $iss    '#define MyAppVersion "0.3.2-dev6"' '#define MyAppVersion "0.3.2-dev7"'
Replace-Exact $proj   '<InformationalVersion>0.3.2-dev6</InformationalVersion>' '<InformationalVersion>0.3.2-dev7</InformationalVersion>'
Replace-Exact $xaml   'Text="v0.3.2-dev6"' 'Text="v0.3.2-dev7"'
Replace-Exact $readme '# Adaptive Media 0.3.2-dev6' '# Adaptive Media 0.3.2-dev7'
Replace-Exact $readme 'AdaptiveMediaSetup-0.3.2-dev6-x64.exe' 'AdaptiveMediaSetup-0.3.2-dev7-x64.exe'
Replace-Exact $conf   '# Adaptive Media 0.3.2-dev6 - managed mpv defaults' '# Adaptive Media 0.3.2-dev7 - managed mpv defaults'
Replace-Exact $input  '# Adaptive Media 0.3.2-dev6' '# Adaptive Media 0.3.2-dev7'

# Fail closed on the exact shipped guard.
$confText = Read-Text $conf
foreach ($needle in @(
    '[motion-guard]',
    'profile-cond=(p.time_pos or 0) > 5 and (p.vsync_jitter or 0) > 0.1 and (p.vo_delayed_frame_count or 0) > 2 * (p.time_pos or 1)',
    'video-sync=audio',
    'interpolation=no'
)) {
    if (-not $confText.Contains($needle)) { throw "Motion guard profile is incomplete: $needle" }
}
if (([regex]::Matches($confText, [regex]::Escape('[motion-guard]'))).Count -ne 1) { throw 'Motion guard profile duplicated.' }
if (([regex]::Matches($confText, [regex]::Escape('profile-cond='))).Count -ne 1) { throw 'Exactly one conditional auto profile is expected in the managed mpv config.' }
# The guard must never be requested explicitly; that would apply it unconditionally.
$engineText = Read-Text (Join-Path $SourceRoot 'payload\AdaptiveMedia.Engine.ps1')
if ($engineText.Contains('--profile=motion-guard')) { throw 'The engine must not request the motion guard explicitly.' }
# The renderer profiles the guard must not disturb.
if ($confText -notmatch '(?ms)^\[compatibility\].*?gpu-api=d3d11.*?gpu-context=d3d11') { throw 'Compatibility profile is no longer explicitly D3D11.' }
if ($confText -notmatch '(?ms)^\[nvidia\].*?gpu-api=vulkan.*?gpu-context=winvk') { throw 'NVIDIA profile is no longer explicitly Vulkan/winvk.' }

# The gate must understand the fallback, or a correct fallback would read as a failure.
$certText = Read-Text $cert
foreach ($needle in @('MotionGuardEngaged', 'Motion guard engaged', 'MotionGuardJitterThreshold')) {
    if (-not $certText.Contains($needle)) { throw "The hardware gate does not recognise the motion guard: $needle" }
}

$readmeText = Read-Text $readme
if (-not $readmeText.Contains('## Automatic motion fallback')) { throw 'Automatic motion fallback is not documented.' }

$issText = Read-Text $iss
if (-not $issText.Contains('#define MyAppVersion "0.3.2-dev7"')) { throw 'Dev7 installer version missing.' }

Write-Host 'Adaptive Media 0.3.2-dev7 automatic motion fallback applied and verified.'
