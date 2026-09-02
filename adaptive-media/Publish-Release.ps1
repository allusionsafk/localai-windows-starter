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
    [string]$Target
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
$installerName = [IO.Path]::GetFileName($Installer)
$checksumName = [IO.Path]::GetFileName($Checksum)
Write-Host "Local installer $installerName SHA-256: $expectedHash"

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
    Invoke-GhChecked -Arguments @(
        'release', 'edit', $Tag, '--title', $Title, '--notes-file', $NotesFile, '--repo', $Repo
    ) -FailureMessage 'Release metadata update failed' | Write-Host
}
else {
    Write-Host "Release $Tag does not exist; creating it."
    $createArgs = @('release', 'create', $Tag, $Installer, $Checksum, '--title', $Title, '--notes-file', $NotesFile, '--repo', $Repo)
    if ($Target) { $createArgs += @('--target', $Target) }
    Invoke-GhChecked -Arguments $createArgs -FailureMessage 'GitHub release creation failed' | Write-Host
}

# --- Verify the published release -------------------------------------------
$assetsJson = Invoke-GhChecked -Arguments @(
    'release', 'view', $Tag, '--repo', $Repo, '--json', 'assets,tagName,name,isDraft'
) -FailureMessage 'Post-publish release verification failed'

$release = $assetsJson | ConvertFrom-Json
if ($release.isDraft) { throw "Release $Tag was published as a draft." }
$assetNames = @($release.assets | ForEach-Object { $_.name })
foreach ($expectedAsset in @($installerName, $checksumName)) {
    if ($assetNames -notcontains $expectedAsset) {
        throw "Published release $Tag is missing asset '$expectedAsset'. Present: $($assetNames -join ', ')"
    }
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
