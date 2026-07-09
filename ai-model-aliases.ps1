#requires -Version 7.0
<#
  Adds purpose-based Ollama aliases so Open WebUI's model dropdown explains
  when to use each model. These aliases reuse the same model blobs; they do
  not download or duplicate the large model files.
#>
$ErrorActionPreference = 'Stop'

$Ollama = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
if (-not (Test-Path $Ollama)) { throw "Ollama not found at $Ollama" }

$aliases = @(
  [pscustomobject]@{ Alias='deep-thinking-qwen3.6';            Source='qwen3.6-thinklight-grounded'; Use='Think-light Qwen3.6; avoids long hidden loops' },
  [pscustomobject]@{ Alias='full-thinking-qwen3.6';            Source='qwen3.6-35b-a3b-grounded'; Use='Full Qwen3.6 thinking; slow and only for hard problems' },
  [pscustomobject]@{ Alias='voice-qwen3-grounded';             Source='qwen3-grounded';           Use='Voice default; strong and responsive' },
  [pscustomobject]@{ Alias='fast-voice-qwen2.5-14b';           Source='qwen2.5:14b';              Use='Fastest voice / quick replies' },
  [pscustomobject]@{ Alias='image-prompt-qwen3-grounded';      Source='qwen3-grounded';           Use='Image prompt help after unloading big chat model' },
  [pscustomobject]@{ Alias='image-fast-prompt-qwen2.5-14b';    Source='qwen2.5:14b';              Use='Fast image prompt help' },
  [pscustomobject]@{ Alias='web-search-qwen3-grounded';        Source='qwen3-grounded';           Use='Web search default; faster synthesis' },
  [pscustomobject]@{ Alias='web-search-deep-qwen3.6';          Source='qwen3.6-thinklight-grounded'; Use='Web search with Qwen3.6 quality, capped thinking' },
  [pscustomobject]@{ Alias='terminal-code-qwen2.5-coder-14b';  Source='qwen2.5-coder:14b';        Use='Smooth local terminal coding agent' },
  [pscustomobject]@{ Alias='terminal-agent-qwen3-coder-30b';   Source='qwen3-coder:30b';          Use='Deep local terminal coding agent; heavier' },
  [pscustomobject]@{ Alias='vision-qwen2.5vl-7b';              Source='qwen2.5vl:7b';             Use='Local image understanding' }
)

function Get-ModelNameSet {
  $set = @{}
  $lines = (& $Ollama list) 2>$null
  foreach ($line in ($lines | Select-Object -Skip 1)) {
    $name = (($line -split '\s+')[0]).Trim()
    if (-not $name) { continue }
    $set[$name] = $true
    $set[($name -replace ':latest$','')] = $true
  }
  return $set
}

# Ollama may auto-start at login and can lag slightly.
$up = $false
for ($i = 0; $i -lt 30; $i++) {
  try {
    Invoke-RestMethod 'http://localhost:11434/api/tags' -TimeoutSec 3 | Out-Null
    $up = $true
    break
  } catch {
    Start-Sleep -Seconds 2
  }
}
if (-not $up) { throw 'Ollama server is not reachable.' }

$existing = Get-ModelNameSet
$failures = 0

foreach ($row in $aliases) {
  if (-not $existing.ContainsKey($row.Source)) {
    Write-Warning "Skipping $($row.Alias): source model '$($row.Source)' is missing."
    $failures++
    continue
  }

  $out = (& $Ollama cp $row.Source $row.Alias) 2>&1
  if ($LASTEXITCODE -eq 0) {
    Write-Host ("[alias] {0,-34} -> {1,-30} {2}" -f $row.Alias, $row.Source, $row.Use)
  } else {
    Write-Warning "Failed to create $($row.Alias): $out"
    $failures++
  }
}

if ($failures -gt 0) { exit 1 }
exit 0
