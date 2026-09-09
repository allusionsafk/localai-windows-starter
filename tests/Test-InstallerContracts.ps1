#requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$script:Pass = 0
$script:Fail = 0
$script:Failures = [System.Collections.Generic.List[string]]::new()

function Assert-True {
  param([string]$Case, $Condition, [string]$Detail = '')
  if ([bool]$Condition) { $script:Pass++; return }
  $script:Fail++
  $script:Failures.Add($(if ($Detail) { "$Case$([Environment]::NewLine)        $Detail" } else { $Case }))
}

function Require-File {
  param([string]$Relative)
  $path = Join-Path $Root $Relative
  Assert-True "$Relative exists" (Test-Path -LiteralPath $path -PathType Leaf)
  return $path
}

$versionPath = Require-File 'installer/version.json'
$toolchainPath = Require-File 'installer/toolchain.json'
$issPath = Require-File 'installer/AFKLocalAI.iss'
$manifestPath = Require-File 'installer/payload-manifest.txt'
$stagePath = Require-File 'scripts/New-ReleasePayload.ps1'
$buildPath = Require-File 'scripts/Build-Installer.ps1'
$gatePath = Require-File 'scripts/Test-DistributionContracts.ps1'

if (Test-Path -LiteralPath $versionPath) {
  $version = Get-Content -LiteralPath $versionPath -Raw | ConvertFrom-Json
  Assert-True 'canonical installer filename' ($version.installer_name -eq 'AFKLocalAISetup-0.2.0-rc1-x64.exe')
}
if (Test-Path -LiteralPath $toolchainPath) {
  $toolchain = Get-Content -LiteralPath $toolchainPath -Raw | ConvertFrom-Json
  Assert-True 'Inno compiler version is pinned' ($toolchain.inno_setup.version -match '^6\.\d+\.\d+$')
  Assert-True 'Inno installer download digest is pinned' ($toolchain.inno_setup.installer_sha256 -match '^[0-9A-F]{64}$')
}

Write-Host '-- Inno installer contract' -ForegroundColor Cyan
if (Test-Path -LiteralPath $issPath) {
  $iss = Get-Content -LiteralPath $issPath -Raw
  $required = [ordered]@{
    'stable product AppId' = [regex]::Escape('AppId={{8A8A2D4D-CE75-4A2D-A39B-56B4206F93D0}')
    'per-user privileges' = '(?m)^PrivilegesRequired=lowest$'
    '64-bit architecture' = '(?m)^ArchitecturesAllowed=x64compatible$'
    '64-bit install mode' = '(?m)^ArchitecturesInstallIn64BitMode=x64compatible$'
    'per-user program directory' = [regex]::Escape('DefaultDirName={localappdata}\Programs\AFK LocalAI')
    'upgrade keeps install directory' = '(?m)^UsePreviousAppDir=yes$'
    'standard uninstall entry' = '(?m)^Uninstallable=yes$'
    'publisher metadata' = '(?m)^AppPublisher=AFK$'
    'support URL metadata' = '(?m)^AppSupportURL='
    'update URL metadata' = '(?m)^AppUpdatesURL='
    'canonical output basename' = [regex]::Escape('OutputBaseFilename=AFKLocalAISetup-{#AppVersion}-x64')
    'numeric Windows product version' = '(?m)^VersionInfoProductVersion=\{#FileVersion\}$'
    'Start Menu app shortcut' = [regex]::Escape('{group}\AFK LocalAI')
    'Start Menu diagnostics shortcut' = '--diagnostics'
    'Start Menu data shortcut' = '--data-folder'
    'Start Menu uninstall shortcut' = [regex]::Escape('{uninstallexe}')
    'optional desktop shortcut' = 'Name: "desktopicon";.*Flags: unchecked'
    'post-install launch' = 'postinstall.*nowait.*skipifsilent'
    'hidden stop on uninstall' = '--stop.*runhidden'
  }
  foreach ($item in $required.GetEnumerator()) {
    Assert-True $item.Key ($iss -match $item.Value) "pattern missing: $($item.Value)"
  }
  Assert-True 'normal installer paths never launch a console host' ($iss -notmatch '(?i)Filename:\s*"\{(?:cmd|sys)\}\\(?:cmd|WindowsPowerShell)')
  Assert-True 'uninstall preserves per-user AFK LocalAI state' ($iss -notmatch '(?i)\[UninstallDelete\][\s\S]*AFK LocalAI')
  Assert-True 'installer embeds no model weights' ($iss -notmatch '(?i)\.gguf|\.safetensors|\.bin\b')
}

Write-Host '-- deterministic payload contract' -ForegroundColor Cyan
if (Test-Path -LiteralPath $manifestPath) {
  $entries = @(Get-Content -LiteralPath $manifestPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
  Assert-True 'payload manifest has no duplicates' (($entries | Sort-Object -Unique).Count -eq $entries.Count)
  Assert-True 'payload includes version metadata' ($entries -contains 'installer/version.json')
  Assert-True 'payload includes provisioning entry point' ($entries -contains 'installer/Install-LocalAI.ps1')
  Assert-True 'payload includes recovery entry point' ($entries -contains 'installer/Invoke-Recovery.ps1')
  Assert-True 'payload includes Python package' ($entries -contains 'src/localai/__init__.py')
  Assert-True 'payload includes support and licence' ($entries -contains 'SUPPORT.md' -and $entries -contains 'LICENSE')
  foreach ($entry in $entries) {
    Assert-True "manifest entry is relative: $entry" (-not [IO.Path]::IsPathRooted($entry) -and $entry -notmatch '(^|[\\/])\.\.([\\/]|$)')
    Assert-True "manifest source exists: $entry" (Test-Path -LiteralPath (Join-Path $Root $entry) -PathType Leaf)
    Assert-True "manifest excludes unsafe/generated content: $entry" ($entry -notmatch '(?i)(^|/)(\.git|build|dist|tests?|skill-observations|logs|backups|__pycache__|bin|obj)(/|$)|\.env$|\.gguf$|\.safetensors$|\.pyc$')
  }
}

foreach ($path in @($stagePath, $buildPath, $gatePath)) {
  if (Test-Path -LiteralPath $path) {
    $text = Get-Content -LiteralPath $path -Raw
    Assert-True "$(Split-Path -Leaf $path) uses strict errors" ($text -match '\$ErrorActionPreference\s*=\s*''Stop''')
  }
}
if (Test-Path -LiteralPath $stagePath) {
  $stage = Get-Content -LiteralPath $stagePath -Raw
  Assert-True 'payload builder rejects traversal' ($stage -match 'IsPathRooted' -and $stage -match '\.\.')
  Assert-True 'payload hashes every selected file' ($stage -match 'Get-FileHash' -and $stage -match 'SHA256')
  Assert-True 'payload manifest records source commit' ($stage -match 'source_commit')
  Assert-True 'payload records files in sorted order' ($stage -match 'Sort-Object')
}
if (Test-Path -LiteralPath $buildPath) {
  $build = Get-Content -LiteralPath $buildPath -Raw
  Assert-True 'build publishes self-contained x64 shell' ($build -match 'dotnet' -and $build -match 'self-contained' -and $build -match 'win-x64')
  Assert-True 'build emits SHA-256 sidecar' ($build -match 'Get-FileHash' -and $build -match 'sha256\.txt')
  Assert-True 'build derives output name from canonical metadata' ($build -match 'installer_name')
  Assert-True 'build verifies the pinned Inno compiler version' ($build -match 'toolchain\.json' -and $build -match 'GetVersionInfo')
}

Write-Host ''
if ($script:Fail) {
  Write-Host "FAILURES ($script:Fail):" -ForegroundColor Red
  foreach ($failure in $script:Failures) { Write-Host "  - $failure" -ForegroundColor Red }
  Write-Host "INSTALLER CONTRACTS FAILED: $script:Pass passed, $script:Fail failed." -ForegroundColor Red
  exit 1
}
Write-Host "INSTALLER CONTRACTS PASSED: $script:Pass passed, 0 failed." -ForegroundColor Green
exit 0
