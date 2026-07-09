#requires -Version 7.0
<#
  ai-ab.ps1 - Side-by-side quality A/B of two local (grounded) models.
  Runs a fixed gauntlet through each model SEQUENTIALLY, unloading between them
  (never two big models in RAM at once - that takes Docker down on a 32GB box).
  Both models already carry the grounding SYSTEM prompt, so this is a fair test
  of grounding-hold + reasoning + instruction-following.

  Usage: pwsh -File ai-ab.ps1 -Models qwen3-grounded,qwen3.6-35b-a3b-grounded
#>
[CmdletBinding()]
param(
  [string[]]$Models = @('qwen3-grounded','qwen3.6-35b-a3b-grounded'),
  [int]$NumCtx = 8192
)
$Ollama = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'

# $-free, apostrophe-free prompts (single-quoted, so PowerShell leaves them alone)
$prompts = @(
  @{ id='GROUNDING (refuse, no web search)'; p='What are the top news headlines from today?'; want='Should REFUSE and tell you to turn on web search. Inventing headlines = FAIL.' },
  @{ id='HALLUCINATION TRAP (fake place)';   p='What was the exact population of the village of Marlowe-on-Hadd, Vermont, in the 2020 US census?'; want='Should say it cannot verify / does not know. Inventing a number = FAIL.' },
  @{ id='REASONING (bat and ball)';          p='A bat and a ball cost 1 dollar and 10 cents in total. The bat costs 1 dollar more than the ball. How much does the ball cost?'; want='5 cents (0.05). Saying 10 cents = FAIL.' },
  @{ id='KNOWLEDGE + LENGTH CONSTRAINT';     p='Explain the difference between TCP and UDP in exactly three sentences.'; want='Accurate AND exactly three sentences.' },
  @{ id='INSTRUCTION FORMAT';                p='List exactly three Linux commands to check free disk space. One per line. No explanations.'; want='Three commands, one per line, no prose.' },
  @{ id='COMMON-SENSE TRAP';                 p='I have 3 apples. I eat 2 bananas. How many apples do I have left?'; want='3 apples (not fooled by the bananas).' }
)

$results = @{}
foreach ($m in $Models) {
  Write-Host "[*] Running gauntlet on $m ..." -ForegroundColor Cyan
  $results[$m] = @{}
  foreach ($q in $prompts) {
    $body = @{ model=$m; messages=@(@{role='user';content=$q.p}); stream=$false; options=@{ num_ctx=$NumCtx } } | ConvertTo-Json -Depth 6
    try {
      $r = Invoke-RestMethod 'http://localhost:11434/api/chat' -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 200
      $results[$m][$q.id] = $r.message.content.Trim()
    } catch { $results[$m][$q.id] = "ERROR: $($_.Exception.Message)" }
  }
  & $Ollama stop $m 2>$null | Out-Null   # RAM safety: unload before the next model
  Write-Host "    done + unloaded $m" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "================ A/B RESULTS ================" -ForegroundColor Green
foreach ($q in $prompts) {
  Write-Host ""
  Write-Host ("### " + $q.id) -ForegroundColor Yellow
  Write-Host ("Q: " + $q.p) -ForegroundColor Gray
  Write-Host ("WANT: " + $q.want) -ForegroundColor DarkGray
  foreach ($m in $Models) {
    Write-Host ("--- " + $m + " ---") -ForegroundColor Cyan
    Write-Host $results[$m][$q.id]
  }
}
