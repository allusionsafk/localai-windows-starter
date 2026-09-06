<#
.SYNOPSIS
    Creates or updates the Adaptive Media GitHub release and verifies the published assets.

.DESCRIPTION
    A missing release leads to creation; an existing release leads to asset replacement and
    metadata refresh. Every genuine gh failure is re-raised.

    gh writes ordinary diagnostics such as "release not found" to stderr. Under
    $ErrorActionPreference = 'Stop', Windows PowerShell converts native stderr output into a
    terminating NativeCommandError before $LASTEXITCODE can be inspected, which is why the
    probe below relaxes the preference only for the duration of each gh invocation and then
    inspects the real exit code. Nothing is suppressed: any non-zero exit that is not an
    explicit "release does not exist" signal is thrown with gh's own output attached.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Tag,
    [Parameter(Mandatory = $true)][string]$Title,
    [Parameter(Mandatory = $true)][string]$NotesFile,
    [Parameter(Mandatory = $true)][string]$Installer,
    [Parameter(Mandatory = $true)][string]$Checksum,
    [Parameter(Mandatory = $true)][string]$Repo,
    [string]$Target,
    [switch]$Prerelease,
    [string]$ExpectedSha256,
    [string]$ExpectedCommit
)

$ErrorActionPreference = 'Stop'

function Invoke-Gh {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & gh @Arguments 2>&1 | ForEach-Object { $_.ToString() }
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }

    [pscustomobject]@{
        ExitCode = $code
        Output   = (@($output) -join [Environment]::NewLine)
    }
}

function Invoke-GhChecked {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$FailureMessage
    )

    $result = Invoke-Gh -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        throw "$FailureMessage (gh exit $($result.ExitCode)): $($result.Output)"
    }
    return $result.Output
}

foreach ($required in @($NotesFile, $Installer, $Checksum)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required release input is missing: $required"
    }
}

$expectedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Installer).Hash.ToUpperInvariant()
$installerBytes = (Get-Item -LiteralPath $Installer).Length
$installerName = [IO.Path]::GetFileName($Installer)
$checksumName = [IO.Path]::GetFileName($Checksum)
Write-Host "Local installer $installerName SHA-256: $expectedHash ($installerBytes bytes)"

# Tested bits are published bits. A caller that knows which artifact was certified
# states its digest here, and publication stops before touching GitHub if the file
# on disk is not that artifact.
if ($ExpectedSha256) {
    $certified = $ExpectedSha256.Trim().ToUpperInvariant()
    if ($certified -notmatch '^[0-9A-F]{64}$') { throw "-ExpectedSha256 is not a SHA-256 digest: $ExpectedSha256" }
    if ($expectedHash -ne $certified) {
        throw "Refusing to publish. The installer on disk hashes to $expectedHash, but the certified artifact is $certified. Publish the certified bits; do not rebuild between certification and publication."
    }
    Write-Host "Local installer matches the certified digest; nothing was rebuilt."
}

# --- Probe -------------------------------------------------------------------
$probe = Invoke-Gh -Arguments @('release', 'view', $Tag, '--repo', $Repo, '--json', 'tagName')
if ($probe.ExitCode -eq 0) {
    $releaseExists = $true
}
elseif ($probe.Output -match '(?i)release not found|HTTP 404|Not Found') {
    $releaseExists = $false
}
else {
    throw "Unable to determine whether release $Tag exists (gh exit $($probe.ExitCode)): $($probe.Output)"
}

# --- Create or update --------------------------------------------------------
if ($releaseExists) {
    Write-Host "Release $Tag already exists; replacing assets and refreshing metadata."
    Invoke-GhChecked -Arguments @(
        'release', 'upload', $Tag, $Installer, $Checksum, '--clobber', '--repo', $Repo
    ) -FailureMessage 'Release asset upload failed' | Write-Host
    $editArgs = @('release', 'edit', $Tag, '--title', $Title, '--notes-file', $NotesFile, '--repo', $Repo)
    # State the flag either way, so re-publishing can neither silently promote a
    # prerelease nor silently demote a stable release.
    $editArgs += ('--prerelease=' + $(if ($Prerelease) { 'true' } else { 'false' }))
    Invoke-GhChecked -Arguments $editArgs -FailureMessage 'Release metadata update failed' | Write-Host
}
else {
    Write-Host "Release $Tag does not exist; creating it."
    $createArgs = @('release', 'create', $Tag, $Installer, $Checksum, '--title', $Title, '--notes-file', $NotesFile, '--repo', $Repo)
    if ($Target) { $createArgs += @('--target', $Target) }
    if ($Prerelease) { $createArgs += '--prerelease' }
    Invoke-GhChecked -Arguments $createArgs -FailureMessage 'GitHub release creation failed' | Write-Host
}

# --- Verify the published release -------------------------------------------
$assetsJson = Invoke-GhChecked -Arguments @(
    'release', 'view', $Tag, '--repo', $Repo, '--json', 'assets,tagName,name,isDraft,isPrerelease,url'
) -FailureMessage 'Post-publish release verification failed'

$release = $assetsJson | ConvertFrom-Json
if ($release.isDraft) { throw "Release $Tag was published as a draft." }
if ($Prerelease -and -not $release.isPrerelease) { throw "Release $Tag was requested as a prerelease but GitHub does not mark it as one." }
if (-not $Prerelease -and $release.isPrerelease) { throw "Release $Tag is marked as a prerelease but was not requested as one." }
$assetNames = @($release.assets | ForEach-Object { $_.name })
foreach ($expectedAsset in @($installerName, $checksumName)) {
    if ($assetNames -notcontains $expectedAsset) {
        throw "Published release $Tag is missing asset '$expectedAsset'. Present: $($assetNames -join ', ')"
    }
}
$installerAsset = @($release.assets | Where-Object { $_.name -eq $installerName })[0]
if ($installerAsset.size -ne $installerBytes) {
    throw "Published asset size $($installerAsset.size) does not match the local installer size $installerBytes."
}
Write-Host "Published asset size verified: $($installerAsset.size) bytes"

# A tag can be created against the wrong commit without any asset looking wrong,
# so resolve the published tag back to a commit and check it.
if ($ExpectedCommit) {
    $tagCommit = (Invoke-GhChecked -Arguments @(
        'api', "repos/$Repo/commits/$Tag", '--jq', '.sha'
    ) -FailureMessage 'Resolving the published tag to a commit failed').Trim()
    if ($tagCommit -ne $ExpectedCommit) {
        throw "Tag $Tag resolves to commit $tagCommit, not the intended commit $ExpectedCommit."
    }
    Write-Host "Tag $Tag resolves to the intended commit $tagCommit"
}

$verifyDir = Join-Path ([IO.Path]::GetTempPath()) ("am-release-verify-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $verifyDir | Out-Null
try {
    Invoke-GhChecked -Arguments @(
        'release', 'download', $Tag, '--repo', $Repo, '--pattern', $installerName, '--dir', $verifyDir, '--clobber'
    ) -FailureMessage 'Downloading the published installer asset for verification failed' | Write-Host

    $downloaded = Join-Path $verifyDir $installerName
    if (-not (Test-Path -LiteralPath $downloaded -PathType Leaf)) {
        throw "The published installer asset was not downloaded to $downloaded."
    }
    $publishedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $downloaded).Hash.ToUpperInvariant()
    if ($publishedHash -ne $expectedHash) {
        throw "Published asset hash mismatch: expected=$expectedHash published=$publishedHash"
    }
    Write-Host "Published asset $installerName SHA-256 verified: $publishedHash"
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $verifyDir -ErrorAction SilentlyContinue
}

Write-Host "Release $Tag ($($release.name)) published with assets: $($assetNames -join ', ')"
Write-Host "Prerelease: $($release.isPrerelease)"
Write-Host "Release page: $($release.url)"
