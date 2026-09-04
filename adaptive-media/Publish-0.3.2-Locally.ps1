#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$Repo = 'allusionsafk/localai-windows-starter'
$Tag = 'v0.3.2'
$Title = 'Adaptive Media 0.3.2'
$RunId = '33729362639'
$ArtifactName = 'AdaptiveMedia-0.3.2-x64'
$ExpectedHead = 'b487e0e51ce836ae5d1e01ca9a9340a4f72abe8c'
$ExpectedSha = '8E8CC44359FEA1A2BB4F5252F145025BB38ECEBB0B0DE66E7669C2C319944DBB'
$Baseline031Sha = 'BA7E088B7DD4FF1D74E5E473DC0CF0AC887206E9F25F8852A925831F80349B8F'
$ExeName = 'AdaptiveMediaSetup-0.3.2-x64.exe'
$ChecksumName = 'AdaptiveMediaSetup-0.3.2-x64.sha256.txt'
$NotesFile = Join-Path $PSScriptRoot 'RELEASE-NOTES-0.3.2.md'
$Work = Join-Path $env:TEMP 'AdaptiveMedia-0.3.2-Publish'
$Download = Join-Path $Work 'certified'
$VerifyDownload = Join-Path $Work 'published'
$CreatedDraft = $false

function Invoke-Gh {
    param(
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [switch]$AllowFailure
    )
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $text = (& gh @Arguments 2>&1 | Out-String).Trim()
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $old
    }
    if ($code -ne 0 -and -not $AllowFailure) {
        throw ("gh {0} failed with exit code {1}:`n{2}" -f ($Arguments -join ' '), $code, $text)
    }
    [pscustomobject]@{ ExitCode = [int]$code; Output = [string]$text }
}

function Get-Release {
    param([string]$ReleaseTag, [switch]$AllowMissing)
    $r = Invoke-Gh -Arguments @('api', "repos/$Repo/releases/tags/$ReleaseTag") -AllowFailure
    if ($r.ExitCode -eq 0) { return ($r.Output | ConvertFrom-Json) }
    if ($AllowMissing -and $r.Output -match '(?i)404|not found') { return $null }
    throw ("Unable to read release {0}: {1}" -f $ReleaseTag, $r.Output)
}

# A draft release has no git tag yet, so GET /releases/tags/<tag> returns 404 for
# it and the tag ref genuinely does not exist. Listing releases is the only way to
# find a draft by the tag it intends to create.
function Find-Release {
    param([string]$ReleaseTag)
    $r = Invoke-Gh -Arguments @('api', "repos/$Repo/releases?per_page=100")
    # PowerShell 5.1 writes a JSON array to the pipeline as ONE object, so
    # @($text | ConvertFrom-Json) yields a single-element array holding the array.
    # Assign first, then wrap, or every lookup silently matches nothing.
    $parsed = $r.Output | ConvertFrom-Json
    $all = @($parsed)
    $match = @($all | Where-Object { [string]$_.tag_name -eq $ReleaseTag })
    if ($match.Count -eq 0) { return $null }
    return $match[0]
}

function Get-Asset {
    param($Release, [string]$Name)
    @($Release.assets | Where-Object { $_.name -eq $Name }) | Select-Object -First 1
}

function Assert-Baseline031 {
    $r = Get-Release -ReleaseTag 'v0.3.1'
    if ($r.draft -or $r.prerelease) { throw 'v0.3.1 baseline is unexpectedly draft/prerelease.' }
    $a = Get-Asset -Release $r -Name 'AdaptiveMediaSetup-0.3.1-x64.exe'
    if ($null -eq $a) { throw 'v0.3.1 baseline installer asset is missing.' }
    $digest = [string]$a.digest
    if ($digest.ToUpperInvariant() -ne ('SHA256:' + $Baseline031Sha)) {
        throw "v0.3.1 baseline digest changed: $digest"
    }
}

function Assert-032Release {
    param($Release, [bool]$ExpectDraft)
    if ($null -eq $Release) { throw 'v0.3.2 release is missing.' }
    if ([string]$Release.tag_name -ne $Tag) { throw "Unexpected tag: $($Release.tag_name)" }
    if ([string]$Release.name -ne $Title) { throw "Unexpected release title: $($Release.name)" }
    if ([bool]$Release.draft -ne $ExpectDraft) { throw "Unexpected draft state: $($Release.draft)" }
    if ([bool]$Release.prerelease) { throw 'v0.3.2 unexpectedly marked prerelease.' }
    $exe = Get-Asset -Release $Release -Name $ExeName
    $sum = Get-Asset -Release $Release -Name $ChecksumName
    if ($null -eq $exe -or $null -eq $sum) { throw 'v0.3.2 release assets are incomplete.' }
    $digest = [string]$exe.digest
    if ($digest.ToUpperInvariant() -ne ('SHA256:' + $ExpectedSha)) {
        throw "Published installer digest mismatch: expected sha256:$ExpectedSha actual $digest"
    }
    return $exe
}

try {
    Write-Host '============================================================'
    Write-Host ' Adaptive Media 0.3.2 - exact-certified-bits publisher'
    Write-Host '============================================================'
    Write-Host ''

    if (-not (Get-Command gh -CommandType Application -ErrorAction SilentlyContinue)) {
        throw 'GitHub CLI (gh) is not available.'
    }
    if (-not (Test-Path -LiteralPath $NotesFile -PathType Leaf)) {
        throw "Release notes are missing: $NotesFile"
    }

    Invoke-Gh -Arguments @('auth','status','--hostname','github.com') | Out-Null
    Assert-Baseline031
    Write-Host 'v0.3.1 frozen baseline: VERIFIED'

    # Look through drafts too, so a half-finished earlier attempt is resumed and
    # verified rather than silently duplicated.
    $existing = Find-Release -ReleaseTag $Tag
    $ResumeDraft = $false
    if ($null -ne $existing) {
        if (-not [bool]$existing.draft) {
            [void](Assert-032Release -Release $existing -ExpectDraft:$false)
            Assert-Baseline031
            Write-Host "v0.3.2 is already correctly published: $($existing.html_url)"
            Write-Host "SHA-256: $ExpectedSha"
            exit 0
        }
        Write-Host 'A draft v0.3.2 from an earlier attempt exists; verifying its assets and resuming it.'
        [void](Assert-032Release -Release $existing -ExpectDraft:$true)
        Write-Host 'Existing draft asset digest on GitHub: VERIFIED'
        $ResumeDraft = $true
    }

    if (-not $ResumeDraft) {
    $run = Invoke-Gh -Arguments @('run','view',$RunId,'--repo',$Repo,'--json','headSha','--jq','.headSha')
    $runHead = $run.Output.Trim()
    if ($runHead -ne $ExpectedHead) {
        throw "Certified run head changed: expected $ExpectedHead actual $runHead"
    }
    Write-Host "Certified source run/head: VERIFIED ($RunId / $runHead)"

    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $Download | Out-Null
    Invoke-Gh -Arguments @('run','download',$RunId,'--repo',$Repo,'--name',$ArtifactName,'--dir',$Download) | Out-Null

    $exePath = Join-Path $Download $ExeName
    $sumPath = Join-Path $Download $ChecksumName
    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) { throw "Certified installer not found after download: $exePath" }
    if (-not (Test-Path -LiteralPath $sumPath -PathType Leaf)) { throw "Certified checksum not found after download: $sumPath" }

    $localSha = (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($localSha -ne $ExpectedSha) {
        throw "Certified artifact hash mismatch: expected $ExpectedSha actual $localSha"
    }
    $sumText = (Get-Content -LiteralPath $sumPath -Raw).ToUpperInvariant()
    if (-not $sumText.Contains($ExpectedSha)) { throw 'Certified checksum text does not contain the certified digest.' }
    Write-Host "Exact certified installer downloaded: VERIFIED"
    Write-Host "SHA-256: $localSha"

    Write-Host ''
    Write-Host 'Creating v0.3.2 as a draft so GitHub can be verified before publication...'
    Invoke-Gh -Arguments @(
        'release','create',$Tag,
        $exePath,$sumPath,
        '--repo',$Repo,
        '--title',$Title,
        '--notes-file',$NotesFile,
        '--target',$ExpectedHead,
        '--draft'
    ) | Out-Null
    $CreatedDraft = $true

    $draft = $null
    for ($i=0; $i -lt 5; $i++) {
        Start-Sleep -Seconds $(if ($i -eq 0) { 1 } else { 2 })
        $draft = Find-Release -ReleaseTag $Tag
        if ($null -ne $draft) {
            try { [void](Assert-032Release -Release $draft -ExpectDraft:$true); break } catch { if ($i -eq 4) { throw } }
        }
    }
    if ($null -eq $draft) { throw 'The v0.3.2 draft was not visible through the releases list after creation.' }
    [void](Assert-032Release -Release $draft -ExpectDraft:$true)
    Write-Host 'Draft asset digest on GitHub: VERIFIED'
    }

    Invoke-Gh -Arguments @('release','edit',$Tag,'--repo',$Repo,'--draft=false','--title',$Title,'--notes-file',$NotesFile) | Out-Null

    # Once published the tag exists, so the by-tag endpoint is authoritative here
    # and proves the tag ref was actually created.
    $public = $null
    for ($i=0; $i -lt 5; $i++) {
        Start-Sleep -Seconds 2
        $public = Get-Release -ReleaseTag $Tag -AllowMissing
        if ($null -ne $public -and -not [bool]$public.draft) { break }
    }
    if ($null -eq $public) { throw 'v0.3.2 was not resolvable by tag after publication.' }
    $publicAsset = Assert-032Release -Release $public -ExpectDraft:$false
    Assert-Baseline031

    New-Item -ItemType Directory -Force -Path $VerifyDownload | Out-Null
    Invoke-Gh -Arguments @('release','download',$Tag,'--repo',$Repo,'--pattern',$ExeName,'--dir',$VerifyDownload,'--clobber') | Out-Null
    $publishedPath = Join-Path $VerifyDownload $ExeName
    $publishedSha = (Get-FileHash -LiteralPath $publishedPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($publishedSha -ne $ExpectedSha) {
        throw "Re-downloaded public installer hash mismatch: expected $ExpectedSha actual $publishedSha"
    }

    Write-Host ''
    Write-Host 'SUCCESS - Adaptive Media 0.3.2 is public.'
    Write-Host $public.html_url
    Write-Host "Installer: $($publicAsset.browser_download_url)"
    Write-Host "SHA-256: $ExpectedSha"
    Write-Host 'v0.3.1 baseline remains unchanged.'

    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
    exit 0
}
catch {
    Write-Host ''
    Write-Host ('PUBLISH FAILED: ' + $_.Exception.Message) -ForegroundColor Red
    if ($CreatedDraft) {
        # Delete the release first. --cleanup-tag is not used here because a draft
        # has no tag ref, and asking to remove one fails with HTTP 422 and masks
        # whether the release itself was actually removed.
        Write-Host 'Cleaning up the draft v0.3.2 release created by this run...'
        try { Invoke-Gh -Arguments @('release','delete',$Tag,'--repo',$Repo,'--yes') -AllowFailure | Out-Null } catch { Write-Host ('Cleanup warning: ' + $_.Exception.Message) }
        try {
            $ref = Invoke-Gh -Arguments @('api', "repos/$Repo/git/refs/tags/$Tag") -AllowFailure
            if ($ref.ExitCode -eq 0) {
                Invoke-Gh -Arguments @('api','-X','DELETE', "repos/$Repo/git/refs/tags/$Tag") -AllowFailure | Out-Null
                Write-Host 'Removed the tag this run created.'
            } else {
                Write-Host 'No v0.3.2 tag was created, so none needed removing.'
            }
        } catch { Write-Host ('Tag cleanup warning: ' + $_.Exception.Message) }
        $left = $null
        try { $left = Find-Release -ReleaseTag $Tag } catch {}
        if ($null -eq $left) { Write-Host 'Verified: no v0.3.2 release remains.' }
        else { Write-Host 'WARNING: a v0.3.2 release still exists and needs manual review.' }
    }
    Write-Host "Temporary evidence, if any, remains under: $Work"
    exit 1
}
