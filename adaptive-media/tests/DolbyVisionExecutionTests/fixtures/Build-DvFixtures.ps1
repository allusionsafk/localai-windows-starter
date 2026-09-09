[CmdletBinding()]
param(
    [string]$Ffmpeg = 'ffmpeg',
    [string]$DoviTool,
    [string]$MkvToolNixDirectory,
    [string]$UpstreamSource
)

$ErrorActionPreference = 'Stop'
$fixtureDirectory = $PSScriptRoot
$adaptiveRoot = [IO.Path]::GetFullPath((Join-Path $fixtureDirectory '..\..\..'))
$artifactsRoot = Join-Path $adaptiveRoot '.artifacts\dv-tests'
$downloads = Join-Path $artifactsRoot 'downloads'
$work = Join-Path $artifactsRoot 'fixture-build'
$doviVersion = '2.3.3'
$doviCommit = 'd1abe0e27ff2c7ab3339614d06db9f8a058af6b2'
$doviArchiveHash = '37ae198f2a535c910befad39fc09c21cded76bf3ef2d5459d542e58c2c158311'
$mkvVersion = '101.0'
$mkvArchiveHash = '4ee52c5065e4a9c2d88462e99bceac249f07eb2d3bfe415838b6f783642c6417'
$sourceBlobs = @{
    'assets/hevc_tests/regular_bl_start_code_4.hevc' = '29c8ecaed93dd869b961e674b92a1d390f721410'
    'assets/hevc_tests/regular_start_code_4.hevc' = '3b9dd1cd65b5a45411a8e7585d6172dc37246a68'
    'assets/hevc_tests/regular_rpu_mel.bin' = '5eefd4a3da6496b7a884a3e829a3bc19d0b89cf2'
    'assets/tests/fel_orig.bin' = 'a7926febb39043d938ebc49dce0a4c043b5b32f0'
}

function Invoke-Checked([string]$Executable, [string[]]$Arguments) {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE`: $Executable $($Arguments -join ' ')"
    }
}

function Assert-Sha256([string]$Path, [string]$Expected) {
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Expected) { throw "SHA-256 mismatch for $Path. Expected $Expected, found $actual." }
}

New-Item -ItemType Directory -Force -Path $downloads | Out-Null

if ([string]::IsNullOrWhiteSpace($DoviTool)) {
    $doviArchive = Join-Path $downloads "dovi_tool-$doviVersion-x86_64-pc-windows-msvc.zip"
    if (-not (Test-Path -LiteralPath $doviArchive)) {
        Invoke-WebRequest -Uri "https://github.com/quietvoid/dovi_tool/releases/download/$doviVersion/dovi_tool-$doviVersion-x86_64-pc-windows-msvc.zip" -OutFile $doviArchive
    }
    Assert-Sha256 $doviArchive $doviArchiveHash
    $doviDirectory = Join-Path $artifactsRoot "dovi_tool-$doviVersion"
    if (-not (Test-Path -LiteralPath (Join-Path $doviDirectory 'dovi_tool.exe'))) {
        Expand-Archive -LiteralPath $doviArchive -DestinationPath $doviDirectory -Force
    }
    $DoviTool = Join-Path $doviDirectory 'dovi_tool.exe'
}

if ([string]::IsNullOrWhiteSpace($MkvToolNixDirectory)) {
    $mkvArchive = Join-Path $downloads "mkvtoolnix-64-bit-$mkvVersion.7z"
    if (-not (Test-Path -LiteralPath $mkvArchive)) {
        Invoke-WebRequest -Uri "https://mkvtoolnix.download/windows/releases/$mkvVersion/mkvtoolnix-64-bit-$mkvVersion.7z" -OutFile $mkvArchive
    }
    Assert-Sha256 $mkvArchive $mkvArchiveHash
    $MkvToolNixDirectory = Join-Path $artifactsRoot "mkvtoolnix-$mkvVersion"
    if (-not (Test-Path -LiteralPath (Join-Path $MkvToolNixDirectory 'mkvmerge.exe'))) {
        New-Item -ItemType Directory -Force -Path $MkvToolNixDirectory | Out-Null
        Invoke-Checked 'tar' @('-xf', $mkvArchive, '-C', $MkvToolNixDirectory, '--strip-components', '1')
    }
}

if ([string]::IsNullOrWhiteSpace($UpstreamSource)) {
    $UpstreamSource = Join-Path $artifactsRoot "dovi_tool-source-$doviVersion"
    if (-not (Test-Path -LiteralPath (Join-Path $UpstreamSource '.git'))) {
        Invoke-Checked 'git' @('clone', '--branch', $doviVersion, '--depth', '1', 'https://github.com/quietvoid/dovi_tool.git', $UpstreamSource)
    }
}

$resolvedCommit = (& git -C $UpstreamSource rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $resolvedCommit -ne $doviCommit) {
    throw "Unexpected dovi_tool source commit: $resolvedCommit"
}
foreach ($entry in $sourceBlobs.GetEnumerator()) {
    $actualBlob = (& git -C $UpstreamSource hash-object $entry.Key).Trim()
    if ($LASTEXITCODE -ne 0 -or $actualBlob -ne $entry.Value) {
        throw "Unexpected upstream blob for $($entry.Key): $actualBlob"
    }
}

$mkvmerge = Join-Path $MkvToolNixDirectory 'mkvmerge.exe'
$mkvpropedit = Join-Path $MkvToolNixDirectory 'mkvpropedit.exe'
foreach ($tool in @($Ffmpeg, $DoviTool, $mkvmerge, $mkvpropedit)) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Required tool not found: $tool" }
}
if ((& $DoviTool --version) -notmatch '^dovi_tool 2\.3\.3$') { throw 'dovi_tool 2.3.3 is required.' }
if ((& $mkvmerge --version | Select-Object -First 1) -notmatch '^mkvmerge v101\.0 ') { throw 'MKVToolNix 101.0 is required.' }
if ((& $Ffmpeg -version | Select-Object -First 1) -notmatch '^ffmpeg version 7\.1(?:\s|-)') { throw 'FFmpeg 7.1 is required for reproducible fixtures.' }

$resolvedArtifacts = [IO.Path]::GetFullPath($artifactsRoot).TrimEnd('\') + '\'
$resolvedWork = [IO.Path]::GetFullPath($work)
if (-not $resolvedWork.StartsWith($resolvedArtifacts, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe fixture work path: $resolvedWork"
}
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Path $work | Out-Null

$baseHevc = Join-Path $UpstreamSource 'assets\hevc_tests\regular_bl_start_code_4.hevc'
$elHevc = Join-Path $UpstreamSource 'assets\hevc_tests\regular_start_code_4.hevc'
$melRpu = Join-Path $UpstreamSource 'assets\hevc_tests\regular_rpu_mel.bin'
$felUnit = Join-Path $UpstreamSource 'assets\tests\fel_orig.bin'
$felRepeated = Join-Path $work 'fel-259-original.bin'
$felRpu = Join-Path $work 'fel-259.bin'
$unit = [IO.File]::ReadAllBytes($felUnit)
$stream = [IO.File]::Open($felRepeated, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try { 1..259 | ForEach-Object { $stream.Write($unit, 0, $unit.Length) } }
finally { $stream.Dispose() }
Invoke-Checked $DoviTool @('editor', '-i', $felRepeated, '-j', (Join-Path $fixtureDirectory 'zero-active-area.json'), '-o', $felRpu)

$audio = Join-Path $work 'fixture.flac'
Invoke-Checked $Ffmpeg @('-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=11', '-c:a', 'flac', '-y', $audio)

function New-DvFixture([string]$Kind, [string]$Rpu, [string]$Seed) {
    $elWithRpu = Join-Path $work "$Kind-el.hevc"
    $profile7 = Join-Path $work "$Kind-profile7.hevc"
    $output = Join-Path $fixtureDirectory "p7-$Kind.mkv"
    Invoke-Checked $DoviTool @('inject-rpu', '-i', $elHevc, '--rpu-in', $Rpu, '-o', $elWithRpu)
    Invoke-Checked $DoviTool @('mux', '--bl', $baseHevc, '--el', $elWithRpu, '-o', $profile7)
    Invoke-Checked $mkvmerge @(
        '--deterministic', $Seed, '-o', $output,
        '--title', "DV Fixture $($Kind.ToUpperInvariant())",
        '--chapters', (Join-Path $fixtureDirectory 'chapters.txt'),
        '--global-tags', (Join-Path $fixtureDirectory 'global-tags.xml'),
        '--attachment-name', 'fixture-note.txt', '--attachment-mime-type', 'text/plain',
        '--attach-file', (Join-Path $fixtureDirectory 'attachment.txt'),
        '--language', '0:eng', '--track-name', "0:DV P7 $($Kind.ToUpperInvariant())",
        '--default-track-flag', '0:yes', '--forced-display-flag', '0:no',
        '--default-duration', '0:24000/1001fps', '--tags', "0:$((Join-Path $fixtureDirectory 'video-tags.xml'))", $profile7,
        '--language', '0:eng', '--track-name', '0:Fixture Audio', '--default-track-flag', '0:yes', $audio,
        '--language', '0:eng', '--track-name', '0:Fixture Subtitle', '--default-track-flag', '0:no',
        '--forced-display-flag', '0:yes', (Join-Path $fixtureDirectory 'fixture.srt')
    )
    Invoke-Checked $mkvpropedit @($output, '--edit', 'info', '--set', 'date=2026-09-09T14:30:21Z')
    $rpuOut = Join-Path $work "$Kind-rpu.bin"
    Invoke-Checked $DoviTool @('extract-rpu', '-i', $output, '-o', $rpuOut)
    $summary = & $DoviTool info --summary -i $rpuOut 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or $summary -notmatch 'Frames:\s+259' -or $summary -notmatch "Profile:\s+7 \($($Kind.ToUpperInvariant())\)") {
        throw "Generated $Kind fixture did not validate as 259-frame Profile 7 $($Kind.ToUpperInvariant())."
    }
    Write-Output "$([IO.Path]::GetFileName($output)) SHA256=$((Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant())"
}

New-DvFixture 'mel' $melRpu 'adaptive-media-dv-mel-v1'
New-DvFixture 'fel' $felRpu 'adaptive-media-dv-fel-v1'
