#requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'contract-common.ps1')
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
  $iss = Get-ContractText -Path $issPath
  $required = [ordered]@{
    'stable product AppId' = [regex]::Escape('#define TestAppId "{{8A8A2D4D-CE75-4A2D-A39B-56B4206F93D0}"')
    'per-user privileges' = '(?m)^PrivilegesRequired=lowest$'
    '64-bit architecture' = '(?m)^ArchitecturesAllowed=x64compatible$'
    '64-bit install mode' = '(?m)^ArchitecturesInstallIn64BitMode=x64compatible$'
    'per-user program directory' = [regex]::Escape('#define TestDefaultDir "{localappdata}\Programs\AFK LocalAI"')
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
    'uninstall stop runs once' = 'RunOnceId: "StopAFKLocalAI"'
  }
  foreach ($item in $required.GetEnumerator()) {
    Assert-True $item.Key ($iss -match $item.Value) "pattern missing: $($item.Value)"
  }
  Assert-True 'normal installer paths never launch a console host' ($iss -notmatch '(?i)Filename:\s*"\{(?:cmd|sys)\}\\(?:cmd|WindowsPowerShell)')
  Assert-True 'uninstall preserves per-user AFK LocalAI state' ($iss -notmatch '(?i)\[UninstallDelete\][\s\S]*AFK LocalAI')
  Assert-True 'installer embeds no model weights' ($iss -notmatch '(?i)\.gguf|\.safetensors|\.bin\b')
  Assert-True 'lifecycle test AppId can be isolated at compile time' ($iss -match '#ifndef TestAppId' -and $iss -match 'AppId=\{#TestAppId\}')
  Assert-True 'lifecycle test install directory can be isolated at compile time' ($iss -match '#ifndef TestDefaultDir' -and $iss -match 'DefaultDirName=\{#TestDefaultDir\}')
  Assert-True 'lifecycle test Start Menu group can be isolated at compile time' ($iss -match '#ifndef TestGroupName' -and $iss -match 'DefaultGroupName=\{#TestGroupName\}')
}

Write-Host '-- newline portability contract' -ForegroundColor Cyan
# Regression: these contracts used to depend on how the checkout materialised
# rather than on what the file says. .NET's multiline '$' matches immediately
# BEFORE the '\n', so on a CRLF checkout the '\r' is still inside the line and a
# pattern like '(?m)^ArchitecturesAllowed=x64compatible$' does not match. A local
# LF clone passed while GitHub's windows-latest runner - which checks out with
# core.autocrlf=true, and therefore CRLF - failed the identical tree.
if (Test-Path -LiteralPath $issPath) {
  $crlfProbe = Join-Path ([IO.Path]::GetTempPath()) ("afk-crlf-" + [guid]::NewGuid().ToString('n') + ".iss")
  try {
    # Re-materialise the real installer directive exactly as a CRLF checkout would.
    $crlfBody = ((Get-ContractText -Path $issPath) -replace "`n", "`r`n")
    [IO.File]::WriteAllText($crlfProbe, $crlfBody)
    Assert-True 'CRLF probe really is CRLF' ([IO.File]::ReadAllText($crlfProbe).Contains("`r`n"))

    $reread = Get-ContractText -Path $crlfProbe
    Assert-True 'contract reader strips CR from a CRLF checkout' (-not $reread.Contains("`r"))
    Assert-True 'contract reader preserves content' ($reread -eq (Get-ContractText -Path $issPath))
    foreach ($item in $required.GetEnumerator()) {
      Assert-True "survives a CRLF checkout: $($item.Key)" ($reread -match $item.Value) `
        "pattern missing under CRLF: $($item.Value)"
    }
  } finally {
    Remove-Item -LiteralPath $crlfProbe -Force -ErrorAction SilentlyContinue
  }
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
    $text = Get-ContractText -Path $path
    Assert-True "$(Split-Path -Leaf $path) uses strict errors" ($text -match '\$ErrorActionPreference\s*=\s*''Stop''')
  }
}
if (Test-Path -LiteralPath $stagePath) {
  $stage = Get-ContractText -Path $stagePath
  Assert-True 'payload builder rejects traversal' ($stage -match 'IsPathRooted' -and $stage -match '\.\.')
  Assert-True 'payload hashes every selected file' ($stage -match 'Get-FileHash' -and $stage -match 'SHA256')
  Assert-True 'payload manifest records source commit' ($stage -match 'source_commit')
  Assert-True 'payload records files in sorted order' ($stage -match 'Sort-Object')
  Assert-True 'payload stages runtime metadata beside the native executable' (
    $stage -match [regex]::Escape("Join-Path `$shell 'version.json'") -and
    $stage -match [regex]::Escape("Join-Path `$staging 'version.json'"))
}
if (Test-Path -LiteralPath $buildPath) {
  $build = Get-ContractText -Path $buildPath
  Assert-True 'build publishes self-contained x64 shell' ($build -match 'dotnet' -and $build -match 'self-contained' -and $build -match 'win-x64')
  Assert-True 'build emits SHA-256 sidecar' ($build -match 'Get-FileHash' -and $build -match 'sha256\.txt')
  Assert-True 'build derives output name from canonical metadata' ($build -match 'installer_name')
  Assert-True 'build verifies the pinned Inno compiler version' ($build -match 'toolchain\.json' -and $build -match 'GetVersionInfo')
}

Write-Host '-- uninstall ownership contract' -ForegroundColor Cyan
# Regression: uninstalling AFK LocalAI must only ever stop resources whose AFK
# ownership is proven. The shipped uninstaller used to run "py -m localai stop",
# which resolves through the ambient `localai` name - on a machine that also has
# the private engineering workbench installed editable that unloaded every
# loaded Ollama model, tore down the workbench's compose project, and
# force-closed Docker Desktop and Ollama machine-wide.
$controllerPath = Require-File 'src/AFKLocalAI.App/ProvisioningController.cs'
$ownershipPath = Require-File 'src/localai/afk_ownership.py'
$stopEntryPath = Require-File 'installer/afk-stop.py'

if (Test-Path -LiteralPath $controllerPath) {
  $controller = Get-ContractText -Path $controllerPath
  $stopMember = [regex]::Match($controller, '(?s)public ProcessSpec Stop\(\).*?;')
  Assert-True 'app exposes a Stop command' $stopMember.Success
  if ($stopMember.Success) {
    $stopText = $stopMember.Value
    Assert-True 'uninstall stop does not invoke the ambient localai package' (
      $stopText -notmatch '"localai"' -and $stopText -notmatch 'Python\(')
    Assert-True 'uninstall stop runs the payload ownership entry point' (
      $stopText -match [regex]::Escape('"afk-stop.py"'))
    Assert-True 'uninstall stop passes an explicit program root' (
      $stopText -match [regex]::Escape('"--program-root"'))
    # Importing the payload writes __pycache__ into the program directory.
    # Setup never installed those files, so its uninstaller never removes them,
    # and the installation survives the uninstall.
    Assert-True 'uninstall stop leaves no bytecode behind' (
      $stopText -match [regex]::Escape('"-B"'))
  }
}

if (Test-Path -LiteralPath $stopEntryPath) {
  $stopEntry = Get-ContractText -Path $stopEntryPath
  Assert-True 'stop entry point resolves the payload package by path' (
    $stopEntry -match 'sys\.path\.insert' -and $stopEntry -match '"src"')
  Assert-True 'stop entry point discards an already-imported localai' (
    $stopEntry -match 'del sys\.modules')
  Assert-True 'stop entry point proves which package answered the import' (
    $stopEntry -match '__file__' -and $stopEntry -match 'startswith')
  Assert-True 'stop entry point refuses rather than guessing' (
    $stopEntry -match 'Refusing to stop shared')
  Assert-True 'stop entry point never fails an uninstall' ($stopEntry -match 'return 0')
  Assert-True 'stop entry point writes no bytecode into the installation' (
    $stopEntry -match 'sys\.dont_write_bytecode\s*=\s*True')
}

if (Test-Path -LiteralPath $ownershipPath) {
  $ownership = Get-ContractText -Path $ownershipPath
  # Strip the module docstring: it names the forbidden operations in order to
  # explain why they are forbidden.
  $ownershipBody = ($ownership -split '"""', 3)[-1]
  # Operation-shaped, not word-shaped: the module's closing report legitimately
  # mentions Docker Desktop and Ollama to say it left them alone.
  $forbidden = [ordered]@{
    'never force-closes processes' = 'taskkill'
    'never stops Docker Desktop' = 'Docker Desktop\.exe|com\.docker\.backend'
    'never invokes Ollama' = 'ollama\.exe|"ollama"|ollama_path|ollama\s+(stop|rm|ps)'
    'never queries loaded models' = 'api/ps|11434'
    'never prunes Docker' = 'prune'
    'never removes volumes' = 'volume rm|--volumes'
    'never removes containers' = '"down"'
  }
  foreach ($rule in $forbidden.GetEnumerator()) {
    Assert-True "ownership module $($rule.Key)" ($ownershipBody -notmatch $rule.Value) `
      "matched: $($rule.Value)"
  }
  Assert-True 'ownership is decided by the compose config file path' (
    $ownershipBody -match 'com\.docker\.compose\.project\.config_files')
  Assert-True 'ownership requires an absolute program root' (
    $ownershipBody -match 'is_absolute')
  Assert-True 'ownership scopes the stop to a proven project name' (
    $ownershipBody -match [regex]::Escape('"--project-name"'))
  Assert-True 'ownership scopes the stop to the owned compose file' (
    $ownershipBody -match [regex]::Escape('"--file"'))
  Assert-True 'ownership fails closed on conflicting projects' (
    $ownershipBody -match 'conflicting project names')
}

if (Test-Path -LiteralPath $manifestPath) {
  $ownershipEntries = @(Get-Content -LiteralPath $manifestPath | ForEach-Object { $_.Trim() })
  Assert-True 'payload ships the ownership module' (
    $ownershipEntries -contains 'src/localai/afk_ownership.py')
  Assert-True 'payload ships the stop entry point' (
    $ownershipEntries -contains 'installer/afk-stop.py')
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
