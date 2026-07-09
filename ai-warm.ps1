#requires -Version 7.0
<#
  ai-warm.ps1 - Preload the default Ollama model so the first chat has no cold
  40s load wait. Run at login by the "AI-Warm" scheduled task (or manually).
  Picks the model from docker-compose.yml DEFAULT_MODELS so it always warms
  whatever your current daily driver is.
#>
[CmdletBinding()]
param(
  [switch]$RequireOllama,
  [string]$Model,
  [string]$KeepAlive = '30m',
  [int]$NumCtx = 0,
  [switch]$UnloadOthers,
  [switch]$SkipIfAnyLoaded
)

$ErrorActionPreference = 'SilentlyContinue'
$Ollama = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'

# which model is the Open WebUI default?
if ($Model) {
  $model = $Model
} else {
  $model = 'qwen2.5-grounded'
  try {
    $c = Get-Content (Join-Path $PSScriptRoot 'docker-compose.yml') -Raw
    $m = [regex]::Match($c, 'DEFAULT_MODELS=([^\s]+)')
    if ($m.Success) { $model = $m.Groups[1].Value }
  } catch { }
}
if ($NumCtx -le 0) {
  $NumCtx = if ($model -like '*qwen3.6*') { 4096 } else { 8192 }
}

if ($SkipIfAnyLoaded -and (Test-Path $Ollama)) {
  try {
    $ps = Invoke-RestMethod 'http://localhost:11434/api/ps' -TimeoutSec 3
    $loadedNames = @($ps.models | ForEach-Object {
      if ($_.name) { [string]$_.name } elseif ($_.model) { [string]$_.model }
    } | Where-Object { $_ })
    if ($loadedNames.Count -gt 0) {
      Write-Host "[AI-Warm] preserving loaded model(s): $($loadedNames -join ', ')"
      exit 0
    }
  } catch {
    Write-Warning "[AI-Warm] could not check loaded models before warmup: $($_.Exception.Message)"
  }
}

if ($UnloadOthers -and (Test-Path $Ollama)) {
  try {
    $ps = Invoke-RestMethod 'http://localhost:11434/api/ps' -TimeoutSec 3
    foreach ($loaded in @($ps.models)) {
      $name = [string]$loaded.name
      if (-not $name) { continue }
      $plain = $name -replace ':latest$',''
      $target = $model -replace ':latest$',''
      if ($plain -eq $target) { continue }
      Write-Host "[AI-Warm] unloading stale model $name"
      & $Ollama stop $name | Out-Null
    }
  } catch {
    Write-Warning "[AI-Warm] could not unload stale models: $($_.Exception.Message)"
  }
}

# wait for the Ollama server (it auto-starts at login; can lag a bit)
$up = $false
for ($i = 0; $i -lt 40; $i++) {
  try { Invoke-RestMethod 'http://localhost:11434/api/tags' -TimeoutSec 3 | Out-Null; $up = $true; break } catch { }
  Start-Sleep -Seconds 5
}
if (-not $up) {
  Write-Warning '[AI-Warm] Ollama server is not reachable; skipping preload.'
  if ($RequireOllama) { exit 1 }
  exit 0
}

# A tiny chat loads the weights into VRAM/RAM while using the model's chat
# template. This avoids /api/generate edge cases with Qwen3.6 wrappers.
try {
  $b = @{
    model = $model
    messages = @(@{ role = 'user'; content = 'warmup' })
    stream = $false
    keep_alive = $KeepAlive
    options = @{
      num_ctx = $NumCtx
      num_predict = 1
      temperature = 0
    }
  } | ConvertTo-Json -Depth 8
  Invoke-RestMethod 'http://localhost:11434/api/chat' -Method Post -Body $b -ContentType 'application/json' -TimeoutSec 420 | Out-Null
  Write-Host "[AI-Warm] preloaded $model (keep_alive=$KeepAlive, num_ctx=$NumCtx)"
  exit 0
} catch {
  Write-Warning "[AI-Warm] failed to preload $model`: $($_.Exception.Message)"
  exit 1
}
