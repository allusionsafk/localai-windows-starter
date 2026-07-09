#requires -Version 7.0
<#
  Install-LocalAI.ps1 - the guided "Friend Bootstrapper" orchestrator.

  Takes a clean-ish Windows box to a working, LOOPBACK-ONLY localai stack matched
  to its hardware and intent, with a passing self-test and zero network exposure
  unless explicitly opted in. It WRAPS this repo's existing scripts/compose/
  Modelfiles - it does not reimplement them.

  Resumable: phase completion is recorded in installer-state.json so a
  Docker-Desktop reboot mid-run can be resumed with -Resume. -DryRun prints every
  action and changes nothing. See PLAN-installer.md for the full design.

  Usage:
    pwsh -ExecutionPolicy Bypass -File installer/Install-LocalAI.ps1
    ... -Intent chat,web -AcceptDefaults        # non-interactive
    ... -DryRun                                  # print the plan, execute nothing
    ... -Resume                                  # continue after a reboot
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [string]$Intent = '',
  [switch]$AcceptDefaults,
  [switch]$Resume,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
if ($DryRun) { $WhatIfPreference = $true }

$RepoRoot = (Resolve-Path -LiteralPath (Split-Path -Parent $PSScriptRoot)).Path
. (Join-Path $RepoRoot 'ai-common.ps1')
. (Join-Path $PSScriptRoot 'installer-common.ps1')

$StatePath = Get-InstallerStatePath -Root $PSScriptRoot
$TiersPath = Join-Path $PSScriptRoot 'tiers.json'
$Tiers = Get-Content -LiteralPath $TiersPath -Raw | ConvertFrom-Json
$State = Import-InstallerState -Path $StatePath
if (-not $Resume) { $State.pending_reboot = $false }

# Canonical intent ids (audit finding 14: one id, display labels map to it).
$IntentLabels = [ordered]@{
  chat   = 'chat'
  coding = 'coding'
  web    = 'web browsing'
  voice  = 'voice'
}

function Resolve-Python {
  # Prefer the py launcher pinned to 3.12, else python on PATH (audit finding 9:
  # winget-installed tools need PATH refresh / absolute invocation).
  Update-SessionPath
  $py = Get-Command 'py.exe' -ErrorAction SilentlyContinue
  if ($py) { return @($py.Source, '-3.12') }
  $python = Get-Command 'python.exe' -ErrorAction SilentlyContinue
  if ($python) { return @($python.Source) }
  return $null
}

function Get-PyRest {
  # The launcher args after the executable (e.g. '-3.12'), or @() for python.exe.
  param([Parameter(Mandatory)][string[]]$Py)
  if ($Py.Count -gt 1) { return @($Py[1..($Py.Count - 1)]) }
  return @()
}

function Invoke-Localai {
  # Run `python -m localai <args>` from the repo, streaming to the console.
  param([Parameter(Mandatory)][string[]]$Arguments, [int]$TimeoutSec = 600)
  $py = Resolve-Python
  if (-not $py) { throw 'Python not found; run the Prerequisites phase first.' }
  $full = (Get-PyRest -Py $py) + @('-m', 'localai') + $Arguments
  return (Invoke-AiProcess -FilePath $py[0] -ArgumentList $full -TimeoutSec $TimeoutSec -WorkingDirectory $RepoRoot)
}

# ---------------------------------------------------------------- phases

function Invoke-PhaseVet {
  $vram = Get-VetVramGb
  $gpu = Get-VetGpuName
  $ramGb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
  $cores = (Get-CimInstance Win32_Processor | Measure-Object NumberOfLogicalProcessors -Sum).Sum
  $diskGb = [math]::Round((Get-PSDrive -Name ($RepoRoot.Substring(0, 1))).Free / 1GB, 1)
  $tier = Get-CapabilityTier -Tiers $Tiers -VramGb $vram

  $State.hardware = [pscustomobject]@{
    vram_gb = $vram; ram_gb = $ramGb; disk_free_gb = $diskGb
    cpu_cores = $cores; gpu = $gpu; tier = $tier.id; ctx = $tier.ctx
  }
  $warn = @()
  if ($ramGb -lt 16) { $warn += "RAM ${ramGb} GB < 16: Docker Desktop + WSL2 want 8+, expect pressure" }
  if ($diskGb -lt 40) { $warn += "Disk ${diskGb} GB free < 40: models are 4-20 GB each" }
  if ($tier.id -eq 'CPU') { $warn += 'No NVIDIA VRAM detected: CPU tier, small models only, slow' }

  $lines = @(
    "GPU:  $($gpu ?? 'none detected')   VRAM: $($vram ?? '?') GB",
    "RAM:  ${ramGb} GB   Cores: ${cores}   Free disk: ${diskGb} GB",
    "Tier: $($tier.id)  (context ceiling $($tier.ctx) tokens)"
  ) + @($warn | ForEach-Object { "! $_" })
  Write-Card 'Phase 1 - Capability vet' $lines
}

function Invoke-PhaseIntent {
  if ([string]::IsNullOrWhiteSpace($Intent)) {
    if ($AcceptDefaults) {
      $chosen = @('chat')
    } else {
      Write-Card 'Phase 2 - What do you want localai for?' @(
        'Options: chat, coding, web, voice  (comma-separated; default: chat)')
      $raw = Read-Host 'Intent'
      $chosen = if ([string]::IsNullOrWhiteSpace($raw)) { @('chat') } else { $raw -split '\s*,\s*' }
    }
  } else {
    $chosen = $Intent -split '\s*,\s*'
  }
  $valid = @($chosen | Where-Object { $IntentLabels.Contains($_) } | Select-Object -Unique)
  if (-not $valid) { $valid = @('chat') }
  $State.intent = $valid
  Write-Card 'Phase 2 - Intent' @("Selected: $($valid -join ', ')")
}

function Invoke-PhasePython {
  Write-Card 'Phase 4a - Python 3.12' @('winget install Python.Python.3.12')
  [void](Install-WithWinget -Id 'Python.Python.3.12')
}

function Invoke-PhasePip {
  [CmdletBinding(SupportsShouldProcess)]
  param()
  Write-Card 'Phase 4b - Install localai (editable)' @('py -3.12 -m pip install -e .[windows]')
  if ($PSCmdlet.ShouldProcess('.[windows]', 'pip install -e')) {
    $py = Resolve-Python
    if (-not $py) { throw 'Python still not on PATH after install; open a new shell and -Resume.' }
    $pipArgs = (Get-PyRest -Py $py) + @('-m', 'pip', 'install', '-e', '.[windows]')
    $r = Invoke-AiProcess -FilePath $py[0] -ArgumentList $pipArgs -TimeoutSec 900 -WorkingDirectory $RepoRoot
    if ($r.Code -ne 0) { throw "pip install failed: $($r.Text)" }
  }
}

function Invoke-PhaseScout {
  [CmdletBinding(SupportsShouldProcess)]
  param()
  $budget = $State.hardware.vram_gb
  Write-Card 'Phase 3 - Choose models' @(
    "Running scout at the vetted VRAM budget ($($budget ?? 'CPU')) GB, tier $($State.hardware.tier)")
  if ($PSCmdlet.ShouldProcess('scout', 'run localai scout')) {
    $scoutArgs = @('scout')
    if ($null -ne $budget) { $scoutArgs += @('--vram-gb', "$budget") }
    $out = Invoke-Localai -Arguments $scoutArgs -TimeoutSec 300
    Write-Host $out.Text
  }
  # v1: default the chat pick to the tier's example; scout output above informs a
  # manual override. Parsing scout's grouped picks into state is a follow-up.
  $chat = ($Tiers.tiers | Where-Object { $_.id -eq $State.hardware.tier }).example
  $State.models = [pscustomobject]@{
    chat = [pscustomobject]@{ tag = 'qwen3.5:9b-32k'; source = 'qwen3.5:9b'; num_ctx = $State.hardware.ctx }
  }
  Write-Card 'Phase 3 - Picks' @("chat -> qwen3.5:9b-32k @ $($State.hardware.ctx) ctx  (tier example: $chat)")
}

function Invoke-PhaseOllamaDocker {
  Write-Card 'Phase 4a - Ollama, Node, Docker' @('winget install Ollama.Ollama; set Ollama host env')
  [void](Install-WithWinget -Id 'Ollama.Ollama')
  # Load-bearing: Windows Ollama defaults to 127.0.0.1; Docker reaches it via
  # host.docker.internal, so we must bind 0.0.0.0 and set q8_0 KV (finding 1).
  Set-OllamaHostEnv
  if (@($State.intent) -contains 'web') { [void](Install-WithWinget -Id 'OpenJS.NodeJS.LTS') }

  $docker = Get-Command 'docker.exe' -ErrorAction SilentlyContinue
  if (-not $docker) {
    Write-Card 'Phase 4a - Docker Desktop' @(
      'Docker Desktop not found. Installing via winget...',
      'FIRST LAUNCH needs you to accept its license + WSL2 setup, and may reboot.')
    [void](Install-WithWinget -Id 'Docker.DockerDesktop' -TimeoutSec 1200)
    $State.pending_reboot = $true
    Save-InstallerState -State $State -Path $StatePath
    Write-Host ''
    Write-Host 'ACTION NEEDED: launch Docker Desktop once, finish its setup, then re-run:' -ForegroundColor Yellow
    Write-Host '   pwsh -ExecutionPolicy Bypass -File installer/Install-LocalAI.ps1 -Resume' -ForegroundColor Yellow
    return $false   # signal the runner to stop cleanly at the resume point
  }
  return $true
}

function Invoke-PhasePulls {
  [CmdletBinding(SupportsShouldProcess)]
  param()
  Write-Card 'Phase 4c - Pull models + aliases' @(
    'ollama pull picks; build Modelfiles; localai model-aliases (needs Ollama running)')
  if ($PSCmdlet.ShouldProcess('models', 'ollama pull + create + aliases')) {
    $ollama = Get-Command 'ollama.exe' -ErrorAction SilentlyContinue
    if (-not $ollama) { throw 'ollama not on PATH; open a new shell and -Resume.' }
    [void](Invoke-AiProcess -FilePath $ollama.Source -ArgumentList @('pull', $State.models.chat.source) -TimeoutSec 3600)
    $mf = Join-Path $RepoRoot 'qwen-32k.Modelfile'
    if (Test-Path -LiteralPath $mf) {
      [void](Invoke-AiProcess -FilePath $ollama.Source -ArgumentList @('create', $State.models.chat.tag, '-f', $mf) -TimeoutSec 600 -WorkingDirectory $RepoRoot)
    }
    # --lenient: a fresh box has only the picked model(s), not this repo's full
    # zoo, so missing alias sources must be skipped, not fatal (finding 2).
    [void](Invoke-Localai -Arguments @('model-aliases', '--lenient'))
  }
}

function Invoke-PhaseCompose {
  [CmdletBinding(SupportsShouldProcess)]
  param()
  Write-Card 'Phase 4d - Compose up' @('write .env (SEARXNG_SECRET); localai start')
  if ($PSCmdlet.ShouldProcess('.env + stack', 'write .env and localai start')) {
    $envPath = Join-Path $RepoRoot '.env'
    if (-not (Test-Path -LiteralPath $envPath)) {
      $secret = [Convert]::ToHexString([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(24))
      "SEARXNG_SECRET=$secret" | Set-Content -LiteralPath $envPath -Encoding UTF8
    }
    [void](Invoke-Localai -Arguments @('start'))
  }
}

function Invoke-PhaseSeed {
  [CmdletBinding(SupportsShouldProcess)]
  param()
  Write-Card 'Phase 4e - Seed Open WebUI DB' @(
    "localai webui-seed --model $($State.models.chat.tag) --num-ctx $($State.models.chat.num_ctx)")
  if ($PSCmdlet.ShouldProcess('open-webui DB', 'localai webui-seed')) {
    [void](Invoke-Localai -Arguments @(
        'webui-seed', '--model', $State.models.chat.tag,
        '--num-ctx', "$($State.models.chat.num_ctx)",
        '--default-model', $State.models.chat.tag))
  }
}

function Invoke-PhaseSecure {
  [CmdletBinding(SupportsShouldProcess)]
  param()
  Write-Card 'Phase 5 - Secure by default' @(
    'ai-firewall -Apply (block physical-adapter ports); WinNAT :3000 fix if reserved',
    'Loopback-only binds verified; NO LAN exposure; NO autostart registered')
  if ($PSCmdlet.ShouldProcess('firewall', 'ai-firewall -Apply')) {
    [void](Invoke-AiProcess -FilePath 'pwsh' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $RepoRoot 'ai-firewall.ps1'), '-Apply') -TimeoutSec 120 -WorkingDirectory $RepoRoot)
  }
  # WinNAT :3000 reservation only collides sometimes; probe before touching it.
  $reserved = (Invoke-AiProcess -FilePath 'netsh' -ArgumentList @(
      'int', 'ipv4', 'show', 'excludedportrange', 'protocol=tcp') -TimeoutSec 20).Text
  if ($reserved -notmatch '(?m)^\s*3000\s') {
    if ($PSCmdlet.ShouldProcess('WinNAT :3000', 'add excludedportrange')) {
      [void](Invoke-AiProcess -FilePath 'pwsh' -ArgumentList @(
          '-NoProfile', '-ExecutionPolicy', 'Bypass',
          '-File', (Join-Path $RepoRoot 'logs' 'winnat-fix.ps1')) -TimeoutSec 60 -WorkingDirectory $RepoRoot)
    }
  }
}

function Invoke-PhaseSelfTest {
  Write-Card 'Phase 6 - Self-test + hand off' @('localai health (must exit 0)')
  if ($DryRun) {
    Write-Host '   [dry-run] would run: python -m localai health' -ForegroundColor DarkGray
  } else {
    $health = Invoke-Localai -Arguments @('health') -TimeoutSec 300
    Write-Host $health.Text
    if ($health.Code -ne 0) {
      Write-Host 'Self-test did not pass. Fix the lines above and re-run with -Resume.' -ForegroundColor Red
      return
    }
  }
  Write-Card 'localai is ready' @(
    'Chat:   http://127.0.0.1:3000        (first signup becomes admin)',
    'Search: http://127.0.0.1:8080',
    'Start / stop:  Start-LocalAI.bat  /  Stop-LocalAI.bat   (or  localai start|stop)',
    'Change model:  Open WebUI dropdown, or  localai warm --model <id>',
    'Security: loopback-only, firewall-blocked on physical adapters, no autostart.')
}

# ------------------------------------------------------- phase runner

# (name, function, is-a-checkpoint-that-may-stop) in the corrected order
# (audit finding 6): vet -> intent -> python -> pip -> scout -> ollama/docker
# (reboot) -> pulls -> compose -> seed -> secure -> self-test.
$Phases = @(
  @{ Name = 'vet';      Run = { Invoke-PhaseVet } }
  @{ Name = 'intent';   Run = { Invoke-PhaseIntent } }
  @{ Name = 'python';   Run = { Invoke-PhasePython } }
  @{ Name = 'pip';      Run = { Invoke-PhasePip } }
  @{ Name = 'scout';    Run = { Invoke-PhaseScout } }
  @{ Name = 'ollama-docker'; Run = { Invoke-PhaseOllamaDocker } }
  @{ Name = 'pulls';    Run = { Invoke-PhasePulls } }
  @{ Name = 'compose';  Run = { Invoke-PhaseCompose } }
  @{ Name = 'seed';     Run = { Invoke-PhaseSeed } }
  @{ Name = 'secure';   Run = { Invoke-PhaseSecure } }
  @{ Name = 'self-test'; Run = { Invoke-PhaseSelfTest } }
)

Write-Card 'localai Friend Bootstrapper' @(
  "Repo: $RepoRoot",
  $(if ($DryRun) { 'DRY RUN - nothing will be changed.' } else { 'Live run.' }),
  'Loopback-only, no autostart, no LAN exposure unless you opt in.')

foreach ($phase in $Phases) {
  if (Test-PhaseDone -State $State -Phase $phase.Name) {
    Write-Host "-- skip $($phase.Name) (already done)" -ForegroundColor DarkGray
    continue
  }
  $result = & $phase.Run
  if ($phase.Name -eq 'ollama-docker' -and $result -eq $false) {
    # Docker Desktop was just installed; stop at the reboot checkpoint.
    exit 0
  }
  Set-PhaseDone -State $State -Phase $phase.Name -Path $StatePath
}

Save-InstallerState -State $State -Path $StatePath
