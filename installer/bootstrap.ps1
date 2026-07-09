<#
  bootstrap.ps1 - tiny downloadable entry point for the localai Friend Bootstrapper.

  Gets a novice from "nothing" to running the guided installer:
    1. ensure PowerShell 7 (winget-install it, then relaunch under pwsh),
    2. fetch this repo (git clone, else the GitHub zip with path-containment guards),
    3. hand off to installer/Install-LocalAI.ps1.

  Runs under Windows PowerShell 5.1 on a clean box (the orchestrator needs 7.0,
  so this stub deliberately does NOT #require it). Launch it explicitly - a
  double-clicked .ps1 opens Notepad:
    pwsh  -ExecutionPolicy Bypass -File installer\bootstrap.ps1     (if you have 7)
    powershell -ExecutionPolicy Bypass -File installer\bootstrap.ps1 (clean box)

  Distribution is PINNED (audit finding 7): -Ref is a released tag, and the
  download is verified against a known commit SHA (git path) or zip SHA256 (no-git
  path). It fails closed if the pins are unset, so a friend can never run an
  unverified download. MAINTAINER: after cutting the tag, fill $ExpectedCommit
  (git rev-list -n1 <tag>) and $ExpectedZipSha256 (SHA256 of the tag source zip) -
  see installer/README.md. Use -AllowUnverified only for local dev testing.
#>
[CmdletBinding()]
param(
  [string]$Owner = 'allusionsafk',
  [string]$Repo = 'localai-windows-starter',
  [string]$Ref = 'v0.1.0',
  # Filled once the tag is cut; verified after fetch. Empty = not yet pinned.
  [string]$ExpectedCommit = '',
  [string]$ExpectedZipSha256 = '',
  [switch]$AllowUnverified,
  [string]$Destination = (Join-Path $env:USERPROFILE 'localai'),
  [string[]]$InstallerArgs = @()
)

$ErrorActionPreference = 'Stop'

if (-not $AllowUnverified -and -not $ExpectedCommit -and -not $ExpectedZipSha256) {
  throw @"
This bootstrap is not yet pinned for distribution ($Owner/$Repo@$Ref).
A maintainer must set -ExpectedCommit and -ExpectedZipSha256 for the release tag
(see installer/README.md). For local dev testing only, pass -AllowUnverified.
"@
}

function Test-Pwsh7 {
  $pwsh = Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue
  return [bool]$pwsh
}

function Install-Pwsh7 {
  $winget = Get-Command 'winget.exe' -ErrorAction SilentlyContinue
  if (-not $winget) {
    throw 'winget not found. Install PowerShell 7 from https://aka.ms/powershell-release then re-run.'
  }
  Write-Host 'Installing PowerShell 7 via winget...' -ForegroundColor Cyan
  & $winget.Source install --id 'Microsoft.PowerShell' -e `
    --accept-package-agreements --accept-source-agreements
}

function Get-Repo {
  param([Parameter(Mandatory)][string]$Into)

  $parent = Split-Path -Parent $Into
  if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  $parentResolved = (Resolve-Path -LiteralPath $parent).Path

  $git = Get-Command 'git.exe' -ErrorAction SilentlyContinue
  if ($git) {
    if (Test-Path -LiteralPath (Join-Path $Into '.git')) {
      Write-Host "Repo already present at $Into; skipping clone." -ForegroundColor DarkGray
      return
    }
    & $git.Source clone --depth 1 --branch $Ref "https://github.com/$Owner/$Repo.git" $Into
    if ($LASTEXITCODE -ne 0) { throw "git clone failed (exit $LASTEXITCODE)." }
    if ($ExpectedCommit) {
      $head = (& $git.Source -C $Into rev-parse HEAD).Trim()
      if ($head -ne $ExpectedCommit) {
        Remove-Item -LiteralPath $Into -Recurse -Force -ErrorAction SilentlyContinue
        throw "Commit mismatch: expected $ExpectedCommit, got $head. Refusing to continue."
      }
      Write-Host "Verified commit $head." -ForegroundColor Green
    } elseif (-not $AllowUnverified) {
      throw "No -ExpectedCommit pinned; refusing an unverified clone."
    }
    return
  }

  # No git: download the GitHub tag zip and extract, guarding every path against
  # escaping the destination parent (pattern from Install-Nanobrowser.ps1).
  $zip = Join-Path $parentResolved "$Repo-$Ref.zip"
  $extract = Join-Path $parentResolved "$Repo-extract"
  foreach ($path in @($zip, $extract, $Into)) {
    $full = [System.IO.Path]::GetFullPath($path)
    if (-not $full.StartsWith("$parentResolved\", [StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to write outside ${parentResolved}: $full"
    }
  }
  $url = "https://github.com/$Owner/$Repo/archive/refs/tags/$Ref.zip"
  Write-Host "Downloading $url ..." -ForegroundColor Cyan
  Invoke-WebRequest -Uri $url -OutFile $zip -TimeoutSec 180
  if ($ExpectedZipSha256) {
    $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    if ($actual -ne $ExpectedZipSha256.ToUpperInvariant()) {
      Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
      throw "Zip SHA256 mismatch: expected $ExpectedZipSha256, got $actual. Refusing to continue."
    }
    Write-Host "Verified zip SHA256 $actual." -ForegroundColor Green
  } elseif (-not $AllowUnverified) {
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    throw "No -ExpectedZipSha256 pinned and no git available; refusing an unverified download."
  }
  if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force }
  Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
  $inner = Get-ChildItem -LiteralPath $extract -Directory | Select-Object -First 1
  if (-not $inner) { throw 'Downloaded zip had no top-level folder.' }
  if (Test-Path -LiteralPath $Into) { Remove-Item -LiteralPath $Into -Recurse -Force }
  Move-Item -LiteralPath $inner.FullName -Destination $Into
  Remove-Item -LiteralPath $zip, $extract -Recurse -Force -ErrorAction SilentlyContinue
}

# 1. Fetch the repo (works under 5.1 or 7).
Get-Repo -Into $Destination

# 2. Hand off to the orchestrator under pwsh 7.
$orchestrator = Join-Path $Destination 'installer' 'Install-LocalAI.ps1'
if (-not (Test-Path -LiteralPath $orchestrator)) {
  throw "Orchestrator not found at $orchestrator - download may be incomplete."
}

if (-not (Test-Pwsh7)) { Install-Pwsh7 }
$pwsh = (Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue)
if (-not $pwsh) {
  throw 'PowerShell 7 still not found after install. Open a new terminal and run the orchestrator manually.'
}

Write-Host "Launching the guided installer under PowerShell 7..." -ForegroundColor Cyan
& $pwsh.Source -NoProfile -ExecutionPolicy Bypass -File $orchestrator @InstallerArgs
exit $LASTEXITCODE
