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
# Keep the dropdown labels short and stable for backend semantics, but put a
# compact, always-visible explanation immediately underneath each choice.
$profileOld = @'
                            <ComboBox x:Name="ProfileBox" Grid.Column="1" SelectedIndex="0">
                                <ComboBoxItem Content="Automatic"/>
                                <ComboBoxItem Content="Reference"/>
                                <ComboBoxItem Content="Enhanced"/>
                                <ComboBoxItem Content="Compatibility"/>
                            </ComboBox>
'@
$profileNew = @'
                            <StackPanel Grid.Column="1">
                                <ComboBox x:Name="ProfileBox" SelectedIndex="0">
                                    <ComboBoxItem Content="Automatic" ToolTip="Sensible defaults for the current PC and source."/>
                                    <ComboBoxItem Content="Reference" ToolTip="Preserve source cadence and colour intent; avoid optional processing."/>
                                    <ComboBoxItem Content="Enhanced" ToolTip="Use the selected opt-in processing features for this launch."/>
                                    <ComboBoxItem Content="Compatibility" ToolTip="Use the fallback playback path for troublesome files or drivers."/>
                                </ComboBox>
                                <TextBlock Text="Automatic — sensible defaults  •  Reference — source-faithful  •  Enhanced — tuned processing  •  Compatibility — fallback path"
                                           TextWrapping="Wrap" FontSize="11" Foreground="{StaticResource MutedBrush}" Margin="2,5,0,0"/>
                            </StackPanel>
'@
Replace-Exact $xaml $profileOld $profileNew

$upscaleOld = @'
                            <ComboBox x:Name="UpscaleBox" Grid.Column="4" SelectedIndex="0">
                                <ComboBoxItem Content="Off" Tag="Off"/>
                                <ComboBoxItem Content="High quality" Tag="HighQuality"/>
                                <ComboBoxItem Content="RTX Super Resolution (experimental)" Tag="RtxVsr"/>
                            </ComboBox>
'@
$upscaleNew = @'
                            <StackPanel Grid.Column="4">
                                <ComboBox x:Name="UpscaleBox" SelectedIndex="0">
                                    <ComboBoxItem Content="Off" Tag="Off" ToolTip="No extra upscaling processing."/>
                                    <ComboBoxItem Content="High quality" Tag="HighQuality" ToolTip="EWA Lanczos Sharp scaling for lower-resolution video."/>
                                    <ComboBoxItem Content="RTX Super Resolution (experimental)" Tag="RtxVsr" ToolTip="Optional NVIDIA driver-assisted video upscaling."/>
                                </ComboBox>
                                <TextBlock Text="Off — native scaling  •  High quality — EWA Lanczos Sharp  •  RTX SR — experimental NVIDIA upscaling"
                                           TextWrapping="Wrap" FontSize="11" Foreground="{StaticResource MutedBrush}" Margin="2,5,0,0"/>
                            </StackPanel>
'@
Replace-Exact $xaml $upscaleOld $upscaleNew

$motionOld = @'
                            <ComboBox x:Name="MotionBox" Grid.Column="1" SelectedIndex="0">
                                <ComboBoxItem Content="Native cadence" Tag="Off"/>
                                <ComboBoxItem Content="Gentle smooth motion" Tag="Gentle"/>
                                <ComboBoxItem Content="Smooth motion" Tag="Smooth"/>
                            </ComboBox>
'@
$motionNew = @'
                            <StackPanel Grid.Column="1">
                                <ComboBox x:Name="MotionBox" SelectedIndex="0">
                                    <ComboBoxItem Content="Native cadence" Tag="Off" ToolTip="Keep the source frame cadence. No interpolation."/>
                                    <ComboBoxItem Content="Gentle smooth motion" Tag="Gentle" ToolTip="Light interpolation to reduce judder while keeping a more natural look."/>
                                    <ComboBoxItem Content="Smooth motion" Tag="Smooth" ToolTip="Stronger interpolation for maximum smoothness; may create a soap-opera look."/>
                                </ComboBox>
                                <TextBlock Text="Native — no interpolation  •  Gentle — lighter smoothing  •  Smooth — strongest smoothing"
                                           TextWrapping="Wrap" FontSize="11" Foreground="{StaticResource MutedBrush}" Margin="2,5,0,0"/>
                            </StackPanel>
'@
Replace-Exact $xaml $motionOld $motionNew

$checksOld = @'
                            <StackPanel Grid.Column="3" Orientation="Horizontal" VerticalAlignment="Center">
                                <CheckBox x:Name="CleanupCheck" Content="Compression cleanup / debanding" Margin="0,0,24,0"/>
                                <CheckBox x:Name="RtxHdrCheck" Content="RTX Video HDR"/>
                            </StackPanel>
'@
$checksNew = @'
                            <StackPanel Grid.Column="3" VerticalAlignment="Center">
                                <StackPanel Orientation="Horizontal">
                                    <CheckBox x:Name="CleanupCheck" Content="Compression cleanup / debanding" Margin="0,0,24,0" ToolTip="Reduce visible banding and compression artefacts in rough encodes."/>
                                    <CheckBox x:Name="RtxHdrCheck" Content="RTX Video HDR" ToolTip="Experimental NVIDIA HDR enhancement. Never enabled automatically."/>
                                </StackPanel>
                                <TextBlock Text="Cleanup — reduces banding/compression artefacts  •  RTX HDR — experimental NVIDIA HDR enhancement"
                                           TextWrapping="Wrap" FontSize="11" Foreground="{StaticResource MutedBrush}" Margin="0,5,0,0"/>
                            </StackPanel>
'@
Replace-Exact $xaml $checksOld $checksNew

$oldHint = '                        <TextBlock Text="Reference keeps source motion and colour intent. Smooth Motion deliberately interpolates frames and may create a soap-opera look. RTX options are never enabled automatically." TextWrapping="Wrap" Foreground="{StaticResource MutedBrush}" Margin="0,14,0,0"/>'
$newHint = '                        <TextBlock Text="Reference mode never enables interpolation, cleanup, RTX Video HDR, or RTX Super Resolution behind your back." TextWrapping="Wrap" Foreground="{StaticResource MutedBrush}" Margin="0,14,0,0"/>'
Replace-Exact $xaml $oldHint $newHint

# ---------------------------------------------------------------------------
# Built-in integration regression coverage
# ---------------------------------------------------------------------------
# Use small exact replacements rather than one multiline block so this remains
# insensitive to CRLF/LF differences in the reconstructed source.
Replace-Exact $program '                !Has(enhanced, "--video-sync=display-resample") ||' "                !Has(enhanced, \"--video-sync=display-resample\") ||`r`n                !Has(enhanced, \"--video-sync-max-factor=10\") ||"
Replace-Exact $program '                !Has(enhanced, "--interpolation=yes") ||' "                !Has(enhanced, \"--interpolation=yes\") ||`r`n                !Has(enhanced, \"--tscale=linear\") ||"
Replace-Exact $program '                !Has(enhanced, "--deband=yes"))' '                !Has(enhanced, "--deband=yes") || Has(enhanced, "--video-sync-max-factor=12"))'

$compatMarker = '            var compatibility = await backend.GetPlaybackPlanAsync('
$gentleBlock = @'
            var gentle = await backend.GetPlaybackPlanAsync(
                syntheticUrl, new PlaybackOptions("Automatic", "Off", "Gentle", false, false));
            if (!Has(gentle, "--video-sync=display-resample") ||
                !Has(gentle, "--video-sync-max-factor=10") ||
                !Has(gentle, "--interpolation=yes") ||
                !Has(gentle, "--tscale=oversample") ||
                Has(gentle, "--video-sync-max-factor=12"))
                return 24;

            var compatibility = await backend.GetPlaybackPlanAsync(
'@
Replace-Exact $program $compatMarker $gentleBlock

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
    'Automatic — sensible defaults',
    'High quality — EWA Lanczos Sharp',
    'Gentle — lighter smoothing',
    'Cleanup — reduces banding/compression artefacts',
    'Text="v0.3.1"'
)) {
    if (-not $verifyXaml.Contains($needle)) { throw "0.3.1 launcher explanation is missing: $needle" }
}

$verifyIss = Read-Text $iss
if ($verifyIss -notmatch '#define MyAppVersion "0\.3\.1"' -or $verifyIss -notmatch 'VersionInfoVersion=0\.3\.1\.0') {
    throw '0.3.1 installer version verification failed.'
}

Write-Host 'Adaptive Media 0.3.1 motion hotfix, launcher explanations, and regression coverage applied and verified.'
