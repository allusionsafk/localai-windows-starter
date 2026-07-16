<#
  installer-common.ps1 - shared helpers for the localai Friend Bootstrapper.

  Dot-source from Install-LocalAI.ps1 (which also dot-sources ai-common.ps1 for
  Invoke-AiProcess / Resolve-AiCommandPath):
      . (Join-Path $PSScriptRoot 'installer-common.ps1')

  OS-specific calls live here so a later macOS/Linux port can swap this one file
  and leave the orchestrator's phase logic intact.
#>

# ---------------------------------------------------------------- state file

function Get-InstallerStatePath {
  param([string]$Root = $PSScriptRoot)
  return (Join-Path $Root 'installer-state.json')
}

function Import-InstallerState {
  # Read the resume/audit state, or a fresh skeleton when none exists.
  param([Parameter(Mandatory)][string]$Path)
  if (Test-Path -LiteralPath $Path) {
    try {
      return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
    } catch {
      throw "installer-state.json is corrupt ($($_.Exception.Message)); delete it to restart."
    }
  }
  return [pscustomobject]@{
    version        = 1
    phases_done    = @()
    hardware       = $null
    intent         = @()
    models         = [pscustomobject]@{}
    pending_reboot = $false
  }
}

function Save-InstallerState {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)]$State,
    [Parameter(Mandatory)][string]$Path
  )
  if ($PSCmdlet.ShouldProcess($Path, 'write installer state')) {
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
  }
}

function Test-PhaseDone {
  param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Phase)
  return (@($State.phases_done) -contains $Phase)
}

function Set-PhaseDone {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)]$State,
    [Parameter(Mandatory)][string]$Phase,
    [Parameter(Mandatory)][string]$Path
  )
  if (Test-PhaseDone -State $State -Phase $Phase) { return }
  if ($PSCmdlet.ShouldProcess($Phase, 'mark phase done')) {
    $State.phases_done = @($State.phases_done) + $Phase
    Save-InstallerState -State $State -Path $Path
  }
}

# ----------------------------------------------------------------- messaging

function Write-Card {
  param(
    [Parameter(Mandatory)][string]$Title,
    [string[]]$Lines = @()
  )
  Write-Host ''
  Write-Host "== $Title ==" -ForegroundColor Cyan
  foreach ($line in $Lines) { Write-Host "   $line" }
}

function Get-InstallerChoice {
  # Prompt for a yes/no; -AcceptDefaults skips the prompt and returns the default.
  param(
    [Parameter(Mandatory)][string]$Question,
    [bool]$Default = $true,
    [switch]$AcceptDefaults
  )
  if ($AcceptDefaults) { return $Default }
  $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
  $answer = Read-Host "$Question $suffix"
  if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
  return ($answer.Trim().ToLowerInvariant() -in @('y', 'yes'))
}

# ------------------------------------------------------------- PATH / winget

function Update-SessionPath {
  # winget installs update the registry PATH but not this process; refresh it so
  # freshly installed tools resolve without a new shell (audit finding 9).
  $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $user = [Environment]::GetEnvironmentVariable('Path', 'User')
  $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Install-WithWinget {
  # Install one package id via winget, idempotently. Returns $true on success or
  # already-present. Mirrors ai-anywhere.ps1's Install-TailscaleWithWinget.
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)][string]$Id,
    [int]$TimeoutSec = 900
  )
  $winget = Get-Command 'winget.exe' -ErrorAction SilentlyContinue
  if (-not $winget) {
    Write-Host "   winget not found; install $Id manually." -ForegroundColor Yellow
    return $false
  }
  $cmdArgs = @(
    'install', '--id', $Id, '-e',
    '--accept-package-agreements', '--accept-source-agreements'
  )
  if (-not $PSCmdlet.ShouldProcess($Id, 'winget install')) { return $true }
  $result = Invoke-AiProcess -FilePath $winget.Source -ArgumentList $cmdArgs -TimeoutSec $TimeoutSec
  Update-SessionPath
  if ($result.Code -eq 0) { return $true }
  # winget exit code for "no applicable upgrade / already installed" is non-fatal.
  Write-Host "   winget $Id -> exit $($result.Code): $($result.Text)" -ForegroundColor Yellow
  return $false
}

# -------------------------------------------------------- user-scope env vars

function Set-UserEnvVar {
  # Set a user-scope env var AND this session's copy so it takes effect now.
  # Used for the load-bearing Ollama vars (audit finding 1).
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Value
  )
  if ($PSCmdlet.ShouldProcess("$Name=$Value", 'set user env var')) {
    [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
    Set-Item -LiteralPath "Env:$Name" -Value $Value
  }
}

# The Ollama host env a fresh box lacks. OLLAMA_HOST is required for
# Docker->Ollama; OLLAMA_KV_CACHE_TYPE=q8_0 is load-bearing for the tier VRAM
# math (tiers.json assumes it).
$script:OllamaUserEnv = [ordered]@{
  OLLAMA_HOST           = '0.0.0.0:11434'
  OLLAMA_KV_CACHE_TYPE  = 'q8_0'
  OLLAMA_FLASH_ATTENTION = '1'
  OLLAMA_KEEP_ALIVE     = '30m'
}

function Set-OllamaHostEnv {
  [CmdletBinding(SupportsShouldProcess)]
  param()
  foreach ($name in $script:OllamaUserEnv.Keys) {
    Set-UserEnvVar -Name $name -Value $script:OllamaUserEnv[$name]
  }
}

# WebBrain (the supported browser-agent extension) calls Ollama's OpenAI-style
# /v1 endpoints straight from its Chrome extension origin, and Ollama 403s
# extension origins it does not know. Allowlist exactly WebBrain's id (stable
# across installs) - deliberately narrower than chrome-extension://*, which
# would let ANY installed extension talk to Ollama. See docs/webbrain.md.
$script:WebBrainOrigin = 'chrome-extension://ljhijonmfahplgbbacgcfnaihbjljhhb'

function Add-OllamaUserOrigin {
  # Append one origin to the user-scope OLLAMA_ORIGINS. Never clobbers: a
  # user's existing custom entries are kept and the origin is only added once.
  [CmdletBinding(SupportsShouldProcess)]
  param([Parameter(Mandatory)][string]$Origin)
  $existing = [Environment]::GetEnvironmentVariable('OLLAMA_ORIGINS', 'User')
  if ($existing -and (@($existing -split '\s*,\s*') -contains $Origin)) { return }
  $value = if ($existing) { "$existing,$Origin" } else { $Origin }
  Set-UserEnvVar -Name 'OLLAMA_ORIGINS' -Value $value
}

# ----------------------------------------------- Phase 1 hardware vet (pure PS)

function Get-VetVramGb {
  # Total VRAM (GB) from nvidia-smi, or $null when absent (never a false 12 -
  # audit finding 4). Win32_VideoController is presence/name only; its AdapterRAM
  # caps at 4 GB, so it is never used for VRAM math.
  $smi = Get-Command 'nvidia-smi' -ErrorAction SilentlyContinue
  if (-not $smi) { return $null }
  $out = Invoke-AiProcess -FilePath $smi.Source -ArgumentList @(
    '--query-gpu=memory.total', '--format=csv,noheader,nounits') -TimeoutSec 15
  if ($out.Code -ne 0 -or -not $out.Text) { return $null }
  $first = ($out.Text -split "`n")[0].Trim()
  $mib = 0.0
  # Invariant culture: TryParse honours the OS locale by default, and e.g. a
  # comma decimal separator would silently mis-parse on non-en-US Windows.
  if (-not [double]::TryParse($first, [System.Globalization.NumberStyles]::Float,
      [System.Globalization.CultureInfo]::InvariantCulture, [ref]$mib)) { return $null }
  return [math]::Round($mib / 1024, 1)
}

function Get-VetGpuName {
  $smi = Get-Command 'nvidia-smi' -ErrorAction SilentlyContinue
  if ($smi) {
    $out = Invoke-AiProcess -FilePath $smi.Source -ArgumentList @(
      '--query-gpu=name', '--format=csv,noheader') -TimeoutSec 15
    if ($out.Code -eq 0 -and $out.Text) { return ($out.Text -split "`n")[0].Trim() }
  }
  $gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty Name
  return $gpu
}

function Get-CapabilityTier {
  # Highest tier whose min_vram_gb the card meets, from tiers.json (the single
  # source shared with installer_vet.classify_tier). Threshold pick only - no fit
  # math duplicated here. $null / 0 VRAM -> CPU.
  param(
    [Parameter(Mandatory)]$Tiers,
    [Nullable[double]]$VramGb
  )
  $usable = if ($null -eq $VramGb) { 0.0 } else { [double]$VramGb }
  $eligible = @($Tiers.tiers | Where-Object { $usable -ge $_.min_vram_gb })
  if (-not $eligible) { return ($Tiers.tiers | Where-Object { $_.id -eq 'CPU' }) }
  return ($eligible | Sort-Object min_vram_gb -Descending | Select-Object -First 1)
}
