[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$adaptiveRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$artifacts = Join-Path $adaptiveRoot '.artifacts\dv-tests'
$doviTool = Join-Path $artifacts 'dovi_tool-2.3.3\dovi_tool.exe'
$mkvToolNix = Join-Path $artifacts 'mkvtoolnix-101.0'
$mkvMerge = Join-Path $mkvToolNix 'mkvmerge.exe'
$mkvExtract = Join-Path $mkvToolNix 'mkvextract.exe'
$mkvPropEdit = Join-Path $mkvToolNix 'mkvpropedit.exe'
$fixtureDirectory = Join-Path $PSScriptRoot 'DolbyVisionExecutionTests\fixtures'
$melFixture = Join-Path $fixtureDirectory 'p7-mel.mkv'
$felFixture = Join-Path $fixtureDirectory 'p7-fel.mkv'
$expectedMel = '76717A9DD5CC11C5774528EE8805AE615031BDBC321E91EED36CE74B5A4DE21D'
$expectedFel = '80E476B5F1D9ED105F9113D2B77412FE19EE9B7CB2548C4382DFFA48C756013F'

function Test-Hash([string]$Path, [string]$Expected) {
    (Test-Path -LiteralPath $Path -PathType Leaf) -and
        ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Expected)
}

$fixturesValid = (Test-Hash $melFixture $expectedMel) -and (Test-Hash $felFixture $expectedFel)
$toolsPresent = @($doviTool, $mkvMerge, $mkvExtract, $mkvPropEdit) |
    ForEach-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    Where-Object { -not $_ } |
    Measure-Object |
    Select-Object -ExpandProperty Count

if (-not $fixturesValid -or $toolsPresent -ne 0) {
    & (Join-Path $fixtureDirectory 'Build-DvFixtures.ps1')
    if ($LASTEXITCODE -ne 0) { throw "Dolby Vision fixture/tool preparation failed with exit code $LASTEXITCODE." }
}

if (-not (Test-Hash $melFixture $expectedMel) -or -not (Test-Hash $felFixture $expectedFel)) {
    throw 'Pinned Dolby Vision fixture hashes do not match after preparation.'
}
foreach ($tool in @($doviTool, $mkvMerge, $mkvExtract, $mkvPropEdit)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "Required pinned tool is missing: $tool" }
}
if ((& $doviTool --version) -notmatch '^dovi_tool 2\.3\.3$') { throw 'dovi_tool 2.3.3 is required.' }
if ((& $mkvMerge --version | Select-Object -First 1) -notmatch '^mkvmerge v101\.0 ') { throw 'MKVToolNix 101.0 is required.' }

$ffprobeCommand = Get-Command ffprobe -ErrorAction Stop
$ffprobe = $ffprobeCommand.Source
if ((& $ffprobe -version | Select-Object -First 1) -notmatch '^ffprobe version 7\.1(?:\s|-)') {
    throw 'FFprobe 7.1 is required for the real execution regression.'
}

$project = Join-Path $PSScriptRoot 'DolbyVisionExecutionTests\DolbyVisionExecutionTests.csproj'
& dotnet run --project $project -- --ffprobe $ffprobe --dovi-tool $doviTool --mkvtoolnix $mkvToolNix
if ($LASTEXITCODE -ne 0) { throw "Real Dolby Vision execution tests failed with exit code $LASTEXITCODE." }
