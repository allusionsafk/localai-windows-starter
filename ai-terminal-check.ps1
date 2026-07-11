#requires -Version 7.0
<#
  ai-terminal-check.ps1 - Fast read-only terminal AI readiness check.

  This verifies the pieces behind ai-chat, ai-code, ai-web, ai-vision, and the
  related wrappers without running a prompt or loading an Ollama model.
#>
[CmdletBinding()]
param(
  [switch]$Strict
)

$ErrorActionPreference = 'SilentlyContinue'
$Root = $PSScriptRoot
$Ok = 0
$Warn = 0
$Fail = 0

function Line([string]$Status, [string]$Name, [string]$Detail) {
  $color = switch ($Status) {
    'OK' { 'Green' }
    'WARN' { 'Yellow' }
    'FAIL' { 'Red' }
    default { 'Gray' }
  }
  if ($Status -eq 'OK') { $script:Ok++ }
  elseif ($Status -eq 'WARN') { $script:Warn++ }
  elseif ($Status -eq 'FAIL') { $script:Fail++ }
  Write-Host ("[{0}] {1,-24} {2}" -f $Status, $Name, $Detail) -ForegroundColor $color
}

function Resolve-CommandSource([string]$Name) {
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

function Test-PathListContains([string]$Dir) {
  $target = try { [IO.Path]::GetFullPath($Dir).TrimEnd('\') } catch { $Dir.TrimEnd('\') }
  foreach ($entry in (($env:PATH -split ';') | Where-Object { $_ })) {
    $full = try { [IO.Path]::GetFullPath($entry).TrimEnd('\') } catch { $entry.TrimEnd('\') }
    if ($full -ieq $target) { return $true }
  }
  return $false
}

. (Join-Path $Root 'ai-common.ps1')   # shared Invoke-AiProcess (was inlined below)
function Invoke-ProcessCaptured([string]$FilePath, [string[]]$ArgumentList = @(), [int]$TimeoutSec = 10) {
  return Invoke-AiProcess $FilePath $ArgumentList $TimeoutSec $Root
}

function Get-OllamaModelNames {
  try {
    $tags = Invoke-RestMethod 'http://localhost:11434/api/tags' -TimeoutSec 5
    return @($tags.models | ForEach-Object {
      if ($_.name) { [string]$_.name } elseif ($_.model) { [string]$_.model }
    } | Where-Object { $_ })
  } catch {
    return $null
  }
}

function Test-ModelKnown([string[]]$Names, [string]$Model) {
  @($Names | Where-Object { $_ -eq $Model -or $_ -like "$Model`:*" }).Count -gt 0
}

Write-Host "==== localai terminal readiness ====  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

$launcher = Join-Path $Root 'Start-TerminalAI.ps1'
if (Test-Path -LiteralPath $launcher) {
  try {
    $null = [scriptblock]::Create((Get-Content -LiteralPath $launcher -Raw))
    Line 'OK' 'Start-TerminalAI' 'syntax OK'
  } catch {
    Line 'FAIL' 'Start-TerminalAI' $_.Exception.Message
  }
} else {
  Line 'FAIL' 'Start-TerminalAI' "missing: $launcher"
}

$binDir = Join-Path $env:USERPROFILE '.local\bin'
if (Test-Path -LiteralPath $binDir -PathType Container) {
  if (Test-PathListContains $binDir) {
    Line 'OK' 'terminal PATH' "$binDir is on PATH"
  } else {
    Line 'WARN' 'terminal PATH' "$binDir exists but is not on PATH for this shell"
  }
} else {
  Line 'FAIL' 'terminal PATH' "$binDir is missing"
}

$commands = @(
  'ai-chat', 'ai-deepchat', 'ai-code', 'ai-deepcode', 'ai-web', 'ai-vision',
  'ai-image', 'ai-models', 'ai-doctor', 'ai-start', 'ai-game-mode', 'ai-agent'
)
foreach ($name in $commands) {
  $source = Resolve-CommandSource $name
  if ($source) {
    Line 'OK' $name $source
  } else {
    $cmdFile = Join-Path $binDir "$name.cmd"
    if (Test-Path -LiteralPath $cmdFile) {
      Line 'WARN' $name "wrapper exists but command did not resolve: $cmdFile"
    } else {
      Line 'FAIL' $name 'missing'
    }
  }
}

$pwsh = Resolve-CommandSource 'pwsh.exe'
if ($pwsh) { Line 'OK' 'PowerShell 7' $pwsh }
else { Line 'FAIL' 'PowerShell 7' 'pwsh.exe not found' }

$ollama = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
if (Test-Path -LiteralPath $ollama) { Line 'OK' 'Ollama binary' $ollama }
else { Line 'FAIL' 'Ollama binary' "missing: $ollama" }

$modelNames = Get-OllamaModelNames
if ($null -eq $modelNames) {
  Line 'WARN' 'Ollama API' 'not reachable; model alias checks skipped'
} else {
  Line 'OK' 'Ollama API' "$($modelNames.Count) model(s) visible"
  $neededModels = @(
    'qwen2.5-grounded',
    'deep-thinking-qwen3.6',
    'terminal-code-qwen2.5-coder-14b',
    'terminal-agent-qwen3-coder-30b',
    'vision-qwen2.5vl-7b',
    'web-search-qwen3-grounded'
  )
  foreach ($model in $neededModels) {
    if (Test-ModelKnown $modelNames $model) {
      Line 'OK' $model 'available'
    } else {
      Line 'WARN' $model 'missing; run ai-model-aliases.ps1 or ai-update.ps1'
    }
  }
}

$aider = Resolve-CommandSource 'aider'
if ($aider) {
  $version = Invoke-ProcessCaptured $aider @('--version') 15
  $detail = if ($version.Text) { $version.Text -replace '\s+', ' ' } else { $aider }
  if ($version.Code -eq 0) { Line 'OK' 'Aider' $detail }
  else { Line 'WARN' 'Aider' $detail }
} else {
  Line 'WARN' 'Aider' 'not found; ai-code falls back to Ollama advice only'
}

$imageGenerator = Join-Path $env:USERPROFILE 'imageai\generate.ps1'
if (Test-Path -LiteralPath $imageGenerator) {
  Line 'OK' 'Image generator' $imageGenerator
} else {
  Line 'WARN' 'Image generator' "missing: $imageGenerator"
}

$searxReady = $false
try {
  $client = [Net.Sockets.TcpClient]::new()
  $iar = $client.BeginConnect('127.0.0.1', 8080, $null, $null)
  $searxReady = $iar.AsyncWaitHandle.WaitOne(750) -and $client.Connected
  $client.Close()
} catch {}
if ($searxReady) { Line 'OK' 'ai-web dependency' 'SearXNG port 8080 is reachable' }
else { Line 'WARN' 'ai-web dependency' 'SearXNG is not reachable; Start Local AI before ai-web' }

Write-Host ("`nSummary: {0} OK, {1} WARN, {2} FAIL" -f $Ok, $Warn, $Fail)
if ($Fail -gt 0) { exit 1 }
if ($Strict -and $Warn -gt 0) { exit 1 }
exit 0
