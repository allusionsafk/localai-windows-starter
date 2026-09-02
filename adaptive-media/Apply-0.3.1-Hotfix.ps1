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
$iss     = Join-Path $SourceRoot 'installer\AdaptiveMedia.iss'
$proj    = Join-Path $SourceRoot 'src\AdaptiveMedia.App\AdaptiveMedia.App.csproj'
$xaml    = Join-Path $SourceRoot 'src\AdaptiveMedia.App\MainWindow.xaml'
$program = Join-Path $SourceRoot 'src\AdaptiveMedia.App\Program.cs'
$readme  = Join-Path $SourceRoot 'README.md'
$mpvConf = Join-Path $SourceRoot 'payload\mpv-config\mpv.conf'
$input   = Join-Path $SourceRoot 'payload\mpv-config\input.conf'

# ---------------------------------------------------------------------------
# 0.3.1 playback fix
# ---------------------------------------------------------------------------
# mpv constrains video-sync-max-factor to 1..10. 0.3.0 emitted 12 for both
# interpolation lanes, causing mpv to reject the command line and exit code 1.
Replace-Exact $engine '--video-sync-max-factor=12' '--video-sync-max-factor=10' 2

# ---------------------------------------------------------------------------
# 0.3.1 version metadata
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Clean in-launcher explanations
# ---------------------------------------------------------------------------
# IMPORTANT: keep user-visible literals in this PowerShell 5.1 patch ASCII-only.
# Windows PowerShell 5.1 can misread UTF-8-without-BOM script literals, which caused
# em dashes / bullets to render as mojibake in the 0.3.1 launcher. Hyphens and pipes
# are intentionally used here so the generated XAML is deterministic on Windows.
Replace-Exact $xaml '<ComboBoxItem Content="Automatic"/>' '<ComboBoxItem Content="Automatic" ToolTip="Sensible defaults for the current PC and source."/>'
Replace-Exact $xaml '<ComboBoxItem Content="Reference"/>' '<ComboBoxItem Content="Reference" ToolTip="Preserve source cadence and colour intent; avoid optional processing."/>'
Replace-Exact $xaml '<ComboBoxItem Content="Enhanced"/>' '<ComboBoxItem Content="Enhanced" ToolTip="Use the selected opt-in processing features for this launch."/>'
Replace-Exact $xaml '<ComboBoxItem Content="Compatibility"/>' '<ComboBoxItem Content="Compatibility" ToolTip="Use the fallback playback path for troublesome files or drivers."/>'
Replace-Exact $xaml '<ComboBoxItem Content="Off" Tag="Off"/>' '<ComboBoxItem Content="Off" Tag="Off" ToolTip="No extra upscaling processing."/>' 1
Replace-Exact $xaml '<ComboBoxItem Content="High quality" Tag="HighQuality"/>' '<ComboBoxItem Content="High quality" Tag="HighQuality" ToolTip="EWA Lanczos Sharp scaling for lower-resolution video."/>'
Replace-Exact $xaml '<ComboBoxItem Content="RTX Super Resolution (experimental)" Tag="RtxVsr"/>' '<ComboBoxItem Content="RTX Super Resolution (experimental)" Tag="RtxVsr" ToolTip="Optional NVIDIA driver-assisted video upscaling."/>'
Replace-Exact $xaml '<ComboBoxItem Content="Native cadence" Tag="Off"/>' '<ComboBoxItem Content="Native cadence" Tag="Off" ToolTip="Keep the source frame cadence. No interpolation."/>'
Replace-Exact $xaml '<ComboBoxItem Content="Gentle smooth motion" Tag="Gentle"/>' '<ComboBoxItem Content="Gentle smooth motion" Tag="Gentle" ToolTip="Light interpolation to reduce judder while keeping a more natural look."/>'
Replace-Exact $xaml '<ComboBoxItem Content="Smooth motion" Tag="Smooth"/>' '<ComboBoxItem Content="Smooth motion" Tag="Smooth" ToolTip="Stronger interpolation for maximum smoothness; may create a soap-opera look."/>'
Replace-Exact $xaml '<CheckBox x:Name="CleanupCheck" Content="Compression cleanup / debanding" Margin="0,0,24,0"/>' '<CheckBox x:Name="CleanupCheck" Content="Compression cleanup / debanding" Margin="0,0,24,0" ToolTip="Reduce visible banding and compression artefacts in rough encodes."/>'
Replace-Exact $xaml '<CheckBox x:Name="RtxHdrCheck" Content="RTX Video HDR"/>' '<CheckBox x:Name="RtxHdrCheck" Content="RTX Video HDR" ToolTip="Experimental NVIDIA HDR enhancement. Never enabled automatically."/>'

# Insert a compact guide below the Preset/Upscaling row.
$secondRowMarker = '                        <Grid Margin="0,14,0,0">'
$firstGuide = @'
                        <Grid Margin="0,6,0,0">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="145"/>
                                <ColumnDefinition Width="260"/>
                                <ColumnDefinition Width="28"/>
                                <ColumnDefinition Width="145"/>
                                <ColumnDefinition Width="260"/>
                            </Grid.ColumnDefinitions>
                            <TextBlock Grid.Column="1" Text="Automatic - sensible defaults | Reference - source-faithful | Enhanced - tuned processing | Compatibility - fallback path"
                                       TextWrapping="Wrap" FontSize="11" Foreground="{StaticResource MutedBrush}"/>
                            <TextBlock Grid.Column="4" Text="Off - native scaling | High quality - EWA Lanczos Sharp | RTX SR - experimental NVIDIA upscaling"
                                       TextWrapping="Wrap" FontSize="11" Foreground="{StaticResource MutedBrush}"/>
                        </Grid>

                        <Grid Margin="0,14,0,0">
'@
Replace-Exact $xaml $secondRowMarker $firstGuide

# Replace the old generic paragraph with specific Motion/Cleanup/RTX guidance.
$oldHint = '                        <TextBlock Text="Reference keeps source motion and colour intent. Smooth Motion deliberately interpolates frames and may create a soap-opera look. RTX options are never enabled automatically." TextWrapping="Wrap" Foreground="{StaticResource MutedBrush}" Margin="0,14,0,0"/>'
$newHint = @'
                        <Grid Margin="0,6,0,0">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="145"/>
                                <ColumnDefinition Width="260"/>
                                <ColumnDefinition Width="28"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <TextBlock Grid.Column="1" Text="Native - no interpolation | Gentle - lighter smoothing | Smooth - strongest smoothing"
                                       TextWrapping="Wrap" FontSize="11" Foreground="{StaticResource MutedBrush}"/>
                            <TextBlock Grid.Column="3" Text="Cleanup - reduces banding/compression artefacts | RTX HDR - experimental NVIDIA HDR enhancement"
                                       TextWrapping="Wrap" FontSize="11" Foreground="{StaticResource MutedBrush}"/>
                        </Grid>
                        <TextBlock Text="Reference mode never enables interpolation, cleanup, RTX Video HDR, or RTX Super Resolution behind your back."
                                   TextWrapping="Wrap" Foreground="{StaticResource MutedBrush}" Margin="0,12,0,0"/>
'@
Replace-Exact $xaml $oldHint $newHint

# ---------------------------------------------------------------------------
# Built-in integration regression coverage
# ---------------------------------------------------------------------------
$displayLine = '                !Has(enhanced, "--video-sync=display-resample") ||'
$displayReplacement = $displayLine + [Environment]::NewLine + '                !Has(enhanced, "--video-sync-max-factor=10") ||'
Replace-Exact $program $displayLine $displayReplacement

$interpLine = '                !Has(enhanced, "--interpolation=yes") ||'
$interpReplacement = $interpLine + [Environment]::NewLine + '                !Has(enhanced, "--tscale=linear") ||'
Replace-Exact $program $interpLine $interpReplacement

Replace-Exact $program '                !Has(enhanced, "--deband=yes"))' '                !Has(enhanced, "--deband=yes") || Has(enhanced, "--video-sync-max-factor=12"))'

$compatMarker = '            var compatibility = await backend.GetPlaybackPlanAsync('
$gentlePrefix = @'
            var gentle = await backend.GetPlaybackPlanAsync(
                syntheticUrl, new PlaybackOptions("Automatic", "Off", "Gentle", false, false));
            if (!Has(gentle, "--video-sync=display-resample") ||
                !Has(gentle, "--video-sync-max-factor=10") ||
                !Has(gentle, "--interpolation=yes") ||
                !Has(gentle, "--tscale=oversample") ||
                Has(gentle, "--video-sync-max-factor=12"))
                return 24;

'@
Replace-Exact $program $compatMarker ($gentlePrefix + $compatMarker)

# ---------------------------------------------------------------------------
# Fail closed verification
# ---------------------------------------------------------------------------
$verifyEngine = Read-Text $engine
if ($verifyEngine -match '--video-sync-max-factor=12') { throw 'Invalid motion max-factor 12 remains in the engine.' }
if (([regex]::Matches($verifyEngine, [regex]::Escape('--video-sync-max-factor=10'))).Count -ne 2) {
    throw 'Expected both Gentle and Smooth motion lanes to use max-factor 10.'
}

$verifyProgram = Read-Text $program
foreach ($needle in @(
    'new PlaybackOptions("Automatic", "Off", "Gentle", false, false)',
    '--video-sync-max-factor=10',
    '--tscale=oversample',
    '--tscale=linear'
)) {
    if (-not $verifyProgram.Contains($needle)) { throw "0.3.1 integration gate is missing: $needle" }
}

$verifyXaml = Read-Text $xaml
foreach ($needle in @(
    'Automatic - sensible defaults',
    'High quality - EWA Lanczos Sharp',
    'Gentle - lighter smoothing',
    'Cleanup - reduces banding/compression artefacts',
    'Reference mode never enables interpolation',
    'Text="v0.3.1"'
)) {
    if (-not $verifyXaml.Contains($needle)) { throw "0.3.1 launcher explanation is missing: $needle" }
}
if ($verifyXaml -match 'â|—|•') {
    throw 'Non-ASCII launcher punctuation or mojibake remains in generated XAML.'
}

$verifyIss = Read-Text $iss
if ($verifyIss -notmatch '#define MyAppVersion "0\.3\.1"' -or $verifyIss -notmatch 'VersionInfoVersion=0\.3\.1\.0') {
    throw '0.3.1 installer version verification failed.'
}

Write-Host 'Adaptive Media 0.3.1 motion hotfix, ASCII-safe launcher explanations, and regression coverage applied and verified.'
