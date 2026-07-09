#requires -Version 7.0
<#
  ai-model-scout.ps1 - Watches for new local-runnable LLMs that could beat your
  current Open WebUI default AND actually fit your machine, then
  pulls + grounds + benchmarks the best one ON YOUR GPU so you can decide.

  Honest scope: a script cannot truly judge "paradigm shift / better than Qwen."
  What it CAN do well, and does here:
    1. DISCOVER new GGUF releases from frontier publishers (Hugging Face API).
    2. SCORE each for fit against THIS box (VRAM/RAM/disk) + your preferences
       (general chat, grounded-able, frontier reasoning/non-reasoning models,
       ~30B-MoE or <=14B-dense).
    3. PREPARE the top pick: pull via Ollama, build a <name>-grounded variant,
       and BENCHMARK it on your 4080 (real tok/s + GPU/CPU split).
    4. REPORT + log so you make the final "make it my default" call.
  It never changes your Open WebUI default on its own unless you run Promote.

  Modes:
    Scout   : discover + score + shortlist + notify. No downloads. (cheap/safe)
    Prepare : (default) Scout, then auto-pull+ground+benchmark the top NEW pick
              that clears the bar. Notifies you it's ready to A/B.
    Promote : like Prepare, but also sets the new grounded model as the Open
              WebUI default (old one kept as fallback). Most autonomous.

  ASCII-only output on purpose (older PS 5.1 mangles non-ASCII). Run under pwsh 7.
#>
[CmdletBinding()]
param(
  [ValidateSet('Scout','Prepare','Promote')]
  [string]$Mode = 'Prepare',
  [string]$Only,                # force-prepare a specific HF repo, e.g. unsloth/Foo-GGUF
  [string]$Quant,               # force a quant tag (e.g. UD-Q3_K_XL); else auto-pick Q4
  [int]$TopN = 8,
  [switch]$NoPull,              # do everything except the big pull (for testing)
  [switch]$Quiet,
  [ValidateRange(30, 14400)]
  [int]$ModelPullTimeoutSec = 7200,
  [ValidateRange(30, 7200)]
  [int]$ModelCreateTimeoutSec = 1200,
  [ValidateRange(30, 1800)]
  [int]$BenchmarkTimeoutSec = 420,
  [ValidateRange(30, 7200)]
  [int]$DockerTimeoutSec = 900,
  [ValidateRange(5, 600)]
  [int]$ProbeTimeoutSec = 30
)

# ------------------------------------------------------------- setup -------
$Root    = $PSScriptRoot
$LogDir  = Join-Path $Root 'logs'
$LogFile = Join-Path $LogDir 'model-scout-log.md'
$State   = Join-Path $LogDir 'model-scout-state.json'
$Lock    = Join-Path $LogDir '.model-scout.lock'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$Ollama  = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
$Compose = Join-Path $Root 'docker-compose.yml'
$HHDR    = @{ 'User-Agent' = 'localai-model-scout' }

# Publishers that ship frontier models as GGUF promptly (configurable).
$Authors = @('unsloth','bartowski','lmstudio-community','Qwen','ggml-org')

# Current daily driver to beat. Read it from docker-compose.yml so the scout
# follows the real setup as it evolves.
$Baseline = 'qwen3.6-35b-a3b-grounded'
try {
  $composeText = Get-Content $Compose -Raw
  $m = [regex]::Match($composeText, 'DEFAULT_MODELS=([^\s]+)')
  if ($m.Success) { $Baseline = $m.Groups[1].Value.Trim() }
} catch { }

# Anti-hallucination grounding (shared by the grounded daily-driver family).
$GroundSystem = @'
You are a precise, grounded assistant.

Answer promptly and visibly. For simple requests, arithmetic, definitions, short explanations, and routine choices, give the final answer directly without opening a reasoning loop.

For hard tasks, do one compact internal check, then answer. Do not repeat the same concern, restart your plan, or write recursive "wait" / "alternatively" loops. After one correction pass, either answer or ask one clarifying question.

If a <think>...</think> section appears, keep it brief, close it, and continue after </think> with a visible final answer. Never end immediately after thinking.

Grounding rules: do not invent facts, numbers, names, dates, quotes, headlines, or events. For current or real-world specifics, use only web-search results provided in the conversation. If no relevant search results are present, say you do not have current data and ask the user to enable web search. If you cannot verify something, say so plainly.

Keep answers concise unless the user asks for depth.
'@

function Say ([string]$m,[string]$c='Gray'){ Write-Host $m -ForegroundColor $c }
$Notes = New-Object System.Collections.Generic.List[string]
function Note([string]$m){ $Notes.Add($m); Say "    $m" 'DarkGray' }
$script:ScoutFailed = $false
function Fail-Scout([string]$m){
  $script:ScoutFailed = $true
  Note $m
}
function Resolve-CommandPath([string]$Name) {
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $Name
}
function Invoke-ProcessCaptured([string]$FilePath, [string[]]$ArgumentList = @(), [int]$TimeoutSec = 300, [string]$WorkingDirectory = $Root) {
  $p = $null
  try {
    $resolved = Resolve-CommandPath $FilePath
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $resolved
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    foreach ($arg in @($ArgumentList)) { [void]$psi.ArgumentList.Add([string]$arg) }

    $p = [System.Diagnostics.Process]::new()
    $p.StartInfo = $psi
    [void]$p.Start()
    $stdoutTask = $p.StandardOutput.ReadToEndAsync()
    $stderrTask = $p.StandardError.ReadToEndAsync()

    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
      try { $p.Kill($true) } catch { try { $p.Kill() } catch { } }
      $cmdLine = "$FilePath $($ArgumentList -join ' ')".Trim()
      return [pscustomobject]@{ Code = 124; Text = "Timed out after ${TimeoutSec}s: $cmdLine" }
    }

    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $text = ((@($stdout, $stderr) | Where-Object { $_ }) -join "`n").Trim()
    return [pscustomobject]@{ Code = $p.ExitCode; Text = $text }
  } catch {
    return [pscustomobject]@{ Code = 1; Text = $_.Exception.Message }
  } finally {
    if ($p) { $p.Dispose() }
  }
}
function Invoke-ProcessChecked([string]$label, [string]$FilePath, [string[]]$ArgumentList = @(), [int]$TimeoutSec = 300) {
  $r = Invoke-ProcessCaptured $FilePath $ArgumentList $TimeoutSec
  if ($r.Code -ne 0) {
    $detail = if ($r.Text) { " - $($r.Text)" } else { '' }
    throw "$label failed (exit $($r.Code))$detail"
  }
  return $r
}
function Invoke-OllamaChecked([string]$label, [string[]]$Arguments, [int]$TimeoutSec = 300) {
  if (-not (Test-Path $Ollama)) { throw "Ollama not found at $Ollama" }
  return Invoke-ProcessChecked $label $Ollama $Arguments $TimeoutSec
}
function Stop-OllamaModel([string]$Model) {
  if (-not $Model -or -not (Test-Path $Ollama)) { return }
  [void](Invoke-ProcessCaptured $Ollama @('stop', $Model) $ProbeTimeoutSec)
}
function Test-OllamaModelPresent([string]$Model) {
  if (-not $Model -or -not (Test-Path $Ollama)) { return $false }
  $list = Invoke-ProcessCaptured $Ollama @('list') $ProbeTimeoutSec
  if ($list.Code -ne 0 -or -not $list.Text) { return $false }
  return [bool]($list.Text | Select-String -SimpleMatch $Model)
}
$script:ModelScoutLock = $null
function Release-ModelScoutLock {
  if ($script:ModelScoutLock) {
    try { $script:ModelScoutLock.Close() } catch { }
    $script:ModelScoutLock = $null
    try { Remove-Item $Lock -Force -ErrorAction SilentlyContinue } catch { }
  }
}

try {
  $script:ModelScoutLock = [System.IO.File]::Open($Lock, 'OpenOrCreate', 'ReadWrite', 'None')
} catch {
  Say "[!] Another model scout run is already in progress (lock held). Exiting." 'Yellow'
  exit 2
}

$exitCode = 0
try {
# ---------------------------------------------------- hardware budget ------
function Get-Budget {
  $ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB,1)
  $vram = 12
  try {
    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if ($smi) {
      $smiResult = Invoke-ProcessCaptured 'nvidia-smi' @('--query-gpu=memory.total', '--format=csv,noheader,nounits') $ProbeTimeoutSec
      $mb = if ($smiResult.Code -eq 0 -and $smiResult.Text) { $smiResult.Text -split "`r?`n" | Select-Object -First 1 } else { $null }
      if ($mb) { $vram = [math]::Round([double]$mb/1024,1) }
    }
  } catch { }
  $disk = [math]::Round((Get-PSDrive C).Free/1GB,1)
  [pscustomobject]@{ RamGB=$ram; VramGB=$vram; DiskFreeGB=$disk }
}

# ------------------------------------------------ state (json hashtable) ---
function Load-State {
  $s = $null
  if (Test-Path $State) { try { $s = Get-Content $State -Raw | ConvertFrom-Json -AsHashtable } catch { } }
  if ($null -eq $s) { $s = @{} }
  foreach ($k in 'prepared','seen') { if (-not $s.ContainsKey($k) -or $null -eq $s[$k]) { $s[$k] = @() } }
  return $s
}
function Save-State($s){ try { $s | ConvertTo-Json -Depth 8 | Set-Content $State -Encoding utf8 } catch { } }

# --------------------------------------------------------- notify ----------
function Show-Notify([string]$title,[string]$message){
  if ($Quiet) { return }
  try { if (Get-Module -ListAvailable -Name BurntToast) { Import-Module BurntToast -EA Stop; New-BurntToastNotification -Text $title,$message -EA Stop; return } } catch { }
  try {
    Add-Type -AssemblyName System.Windows.Forms -EA Stop; Add-Type -AssemblyName System.Drawing -EA Stop
    $ni = New-Object System.Windows.Forms.NotifyIcon
    $ni.Icon=[System.Drawing.SystemIcons]::Information; $ni.Visible=$true
    $ni.BalloonTipTitle=$title; $ni.BalloonTipText=$message; $ni.ShowBalloonTip(10000)
    Start-Sleep -Seconds 6; $ni.Dispose()
  } catch { Note "notify suppressed: $title - $message" }
}

# -------------------------------------------- parse a model id -> facts ----
function Parse-Model([string]$id){
  $author,$repo = $id -split '/',2
  $name = $repo -replace '(?i)-?GGUF$',''
  # strip a leading "OrigOrg_" that bartowski/others prepend
  $clean = $name -replace '^[A-Za-z0-9\.]+_',''
  $lc = $name.ToLower()

  # total params + MoE active (e.g. 30B-A3B, 12B-A2.5B, 8x7B)
  $total = $null; $active = $null; $isMoE = $false
  $mActive = [regex]::Match($name,'(?i)A(\d+(?:\.\d+)?)B')
  if ($mActive.Success) { $active = [double]$mActive.Groups[1].Value; $isMoE = $true }
  $mx = [regex]::Match($name,'(?i)(\d+(?:\.\d+)?)x(\d+(?:\.\d+)?)B')
  if ($mx.Success) { $isMoE = $true; $total = [double]$mx.Groups[1].Value * [double]$mx.Groups[2].Value }
  if ($null -eq $total) {
    foreach ($m in [regex]::Matches($name,'(?i)(?<![A-Za-z])A?(\d+(?:\.\d+)?)B')) {
      $val = [double]$m.Groups[1].Value
      $isActive = $m.Value -match '(?i)^A'
      if (-not $isActive) { if ($null -eq $total -or $val -gt $total) { $total = $val } }
    }
  }
  if ($lc -match 'moe|-a\d') { $isMoE = $true }

  # kind (we want general chat; flag/deprioritize special-purpose)
  $kind = 'general'
  if     ($lc -match 'coder|code') { $kind='coder' }
  elseif ($lc -match 'vl|vision|image-text|multimodal|omni') { $kind='vision' }
  elseif ($lc -match 'embed|gte|bge|e5') { $kind='embed' }
  elseif ($lc -match 'rerank') { $kind='rerank' }
  elseif ($lc -match 'guard|safety|moderation') { $kind='guard' }
  elseif ($lc -match 'diffusion|image-gen|text-to-image') { $kind='diffusion' }
  elseif ($lc -match 'audio|voice|tts|asr|speech') { $kind='audio' }
  elseif ($lc -match 'math|prover') { $kind='math' }
  elseif ($lc -match 'mobile|edge|nano|tiny|-e\db') { $kind='edge' }

  $reasoning = ($lc -match 'thinking|reasoning|-r1|deepseek-r|-cot')
  $parseWarning = if ($null -eq $total) { "WARN: unrecognized model name pattern: $name" } else { $null }

  $fam = 'other'
  foreach ($f in 'qwen','llama','gemma','mixtral','mistral','deepseek','phi','yi','command','glm','granite','olmo','minimax','nemotron','falcon','hermes','smol','stablelm','exaone','internlm') {
    if ($lc -match $f) { $fam = $f; break }
  }
  [pscustomobject]@{
    id=$id; author=$author; name=$clean; total=$total; active=$active; isMoE=$isMoE
    kind=$kind; reasoning=$reasoning; family=$fam; parseWarning=$parseWarning
  }
}

# --------------------------------------------- fit verdict for THIS box ----
function Test-Fit($p,$budget){
  if ($null -eq $p.total) { return @{ verdict='Unknown'; sizeGB=$null; why=($p.parseWarning ?? 'WARN: size not in name') } }
  $sizeGB = [math]::Round($p.total * 0.6, 1)   # rough Q4_K_M footprint
  $ramCeil = $budget.RamGB - 5
  $vramUsable = $budget.VramGB - 1.5            # leave room for KV cache/context
  if ($sizeGB -gt $ramCeil) { return @{ verdict='TooBig'; sizeGB=$sizeGB; why="~${sizeGB}GB > RAM budget" } }
  if ($p.isMoE) {
    if ($p.active -and $p.active -le 6) { return @{ verdict='Good'; sizeGB=$sizeGB; why="MoE ~$($p.active)B active = fast even with CPU offload" } }
    if ($p.active -and $p.active -le 10){ return @{ verdict='OK';   sizeGB=$sizeGB; why="MoE ~$($p.active)B active = usable" } }
    return @{ verdict='OK'; sizeGB=$sizeGB; why='MoE, unknown active' }
  }
  if ($sizeGB -le $vramUsable) { return @{ verdict='Good'; sizeGB=$sizeGB; why="~${sizeGB}GB fits fully in $($budget.VramGB)GB VRAM" } }
  if ($sizeGB -le 18)          { return @{ verdict='Tight'; sizeGB=$sizeGB; why="~${sizeGB}GB spills to CPU = slower" } }
  return @{ verdict='Poor'; sizeGB=$sizeGB; why="~${sizeGB}GB dense = heavy CPU offload" }
}

function Score-Candidate($p,$fit){
  if ($p.kind -ne 'general') { return -1 }                 # only general chat models
  $reputable = ($p.family -ne 'other')
  $s = switch ($fit.verdict) { 'Good'{100} 'OK'{60} 'Tight'{25} default{0} }
  if ($reputable) { $s += 30 }
  if ($p.downloads) { $s += [math]::Min([math]::Log10([math]::Max($p.downloads,1))*10, 40) }
  if ($p.ageDays -ne $null) { if ($p.ageDays -le 21){$s+=20} elseif($p.ageDays -le 45){$s+=10} }
  if (($p.isMoE -and $p.total -ge 24 -and $p.active -le 6) -or (-not $p.isMoE -and $p.total -ge 12 -and $p.total -le 16)) { $s += 20 }  # in daily-driver class
  if ($p.reasoning -and $reputable) { $s += 8 }             # frontier models are increasingly reasoning-capable
  return [math]::Round($s,1)
}

# ------------------------------------------------------ discovery ----------
function Get-Candidates($budget){
  $rows = New-Object System.Collections.Generic.List[object]
  $authorResults = @($Authors | ForEach-Object -ThrottleLimit 4 -Parallel {
    $author = $_
    $headers = $using:HHDR
    try {
      $u = "https://huggingface.co/api/models?author=$author&filter=gguf&sort=lastModified&direction=-1&limit=25"
      $models = @(Invoke-RestMethod $u -Headers $headers -TimeoutSec 30)
      [pscustomobject]@{ Author = $author; Models = $models; Error = $null }
    } catch {
      [pscustomobject]@{ Author = $author; Models = @(); Error = $_.Exception.Message }
    }
  })

  foreach ($result in $authorResults) {
    if ($result.Error) {
      Note "HF query failed for $($result.Author) : $($result.Error)"
      continue
    }
    foreach ($m in @($result.Models)) {
      $p = Parse-Model $m.id
      $p | Add-Member NoteProperty downloads ([int]($m.downloads)) -Force
      $age = $null; try { $age = [int]((Get-Date) - [datetime]$m.lastModified).TotalDays } catch { }
      $p | Add-Member NoteProperty ageDays $age -Force
      $p | Add-Member NoteProperty modified ([string]$m.lastModified) -Force
      $fit = Test-Fit $p $budget
      $p | Add-Member NoteProperty verdict $fit.verdict -Force
      $p | Add-Member NoteProperty sizeGB  $fit.sizeGB  -Force
      $p | Add-Member NoteProperty fitWhy  $fit.why     -Force
      $p | Add-Member NoteProperty score (Score-Candidate $p $fit) -Force
      $rows.Add($p)
    }
  }
  # dedup same underlying model across publishers (keep highest score)
  $byKey = @{}
  foreach ($p in $rows) {
    $key = ($p.name.ToLower() -replace '[^a-z0-9]','')
    if (-not $byKey.ContainsKey($key) -or $p.score -gt $byKey[$key].score) { $byKey[$key] = $p }
  }
  return $byKey.Values | Sort-Object score -Descending
}

# ---------------------------------------- pick a Q4 quant from the repo ----
function Get-BestQuant([string]$repo){
  try {
    $tree = Invoke-RestMethod "https://huggingface.co/api/models/$repo/tree/main" -Headers $HHDR -TimeoutSec 30
    $quants = @()
    foreach ($f in $tree) {
      if ($f.path -match '(?i)\.gguf$') {
        $q = [regex]::Match($f.path,'(?i)(UD-)?(I?Q\d[0-9A-Z_]*)').Value
        if ($q) { $quants += $q }
      }
    }
    $quants = $quants | Select-Object -Unique
    foreach ($pref in 'Q4_K_M','UD-Q4_K_XL','Q4_K_S','IQ4_XS','IQ4_NL','Q4_0','Q3_K_M') {
      $hit = $quants | Where-Object { $_ -ieq $pref } | Select-Object -First 1
      if ($hit) { return $hit }
    }
    return ($quants | Select-Object -First 1)
  } catch { return $null }
}

# --------------------------------------------- grounding factory -----------
function New-GroundedModel($repo,$quant,$p){
  $slug = ($p.name.ToLower() -replace '[^a-z0-9\.]+','-').Trim('-')
  if ($slug.Length -gt 40) { $slug = $slug.Substring(0,40).Trim('-') }
  $gname = "$slug-grounded"
  $template = if ($p.family -eq 'qwen') {
@'
TEMPLATE """
{{- if or .System .Tools }}<|im_start|>system
{{ if .System }}
{{ .System }}
{{- end }}
{{- if .Tools }}

# Tools

You may call one or more functions to assist with the user query.

You are provided with function signatures within <tools></tools> XML tags:
<tools>
{{- range .Tools }}
{"type": "function", "function": {{ .Function }}}
{{- end }}
</tools>

For each function call, return a json object with function name and arguments within <tool_call></tool_call> XML tags:
<tool_call>
{"name": <function-name>, "arguments": <args-json-object>}
</tool_call>
{{- end -}}
<|im_end|>
{{ end }}
{{- range $i, $_ := .Messages }}
{{- $last := eq (len (slice $.Messages $i)) 1 -}}
{{- if eq .Role "user" }}<|im_start|>user
{{ .Content }}<|im_end|>
{{ else if eq .Role "assistant" }}<|im_start|>assistant
{{ if .Content }}{{ .Content }}
{{- else if .ToolCalls }}<tool_call>
{{ range .ToolCalls }}{"name": "{{ .Function.Name }}", "arguments": {{ .Function.Arguments }}}
{{ end }}</tool_call>
{{- end }}{{ if not $last }}<|im_end|>
{{ end }}
{{- else if eq .Role "tool" }}<|im_start|>user
<tool_response>
{{ .Content }}
</tool_response><|im_end|>
{{ end }}
{{- if and (ne .Role "assistant") $last }}<|im_start|>assistant
<think>

</think>

{{ end }}
{{- end }}"""
'@
  } else { '' }
  # family-appropriate sampling (grounded = conservative)
  $samp = switch ($p.family) {
    'qwen'  { "PARAMETER temperature 0.7`nPARAMETER top_p 0.8`nPARAMETER top_k 20`nPARAMETER min_p 0`nPARAMETER repeat_penalty 1.05" }
    'gemma' { "PARAMETER temperature 0.7`nPARAMETER top_p 0.95`nPARAMETER top_k 64" }
    'llama' { "PARAMETER temperature 0.6`nPARAMETER top_p 0.9" }
    'mistral'{ "PARAMETER temperature 0.6`nPARAMETER top_p 0.9" }
    default { "PARAMETER temperature 0.6`nPARAMETER top_p 0.9" }
  }
  $mf = @"
FROM hf.co/$repo`:$quant

# Auto-generated by ai-model-scout on $(Get-Date -Format 'yyyy-MM-dd'). Grounded wrapper.
$template
PARAMETER num_ctx 8192
$samp

SYSTEM """$GroundSystem"""
"@
  $mfPath = Join-Path $Root ("scout-$slug.Modelfile")
  Set-Content -Path $mfPath -Value $mf -Encoding ascii
  Say "    building $gname (FROM hf.co/$repo`:$quant)" 'Cyan'
  [void](Invoke-OllamaChecked "ollama create $gname" @('create', $gname, '-f', $mfPath) $ModelCreateTimeoutSec)
  return $gname
}

# ----------------------------------------- benchmark on the real GPU -------
function Measure-Speed([string]$model){
  $body = @{ model=$model; prompt='Explain how a four-stroke engine works, in two short paragraphs.'; stream=$false; options=@{ num_ctx=8192 } } | ConvertTo-Json
  try {
    $r = Invoke-RestMethod 'http://localhost:11434/api/generate' -Method Post -Body $body -ContentType 'application/json' -TimeoutSec $BenchmarkTimeoutSec
    $tps = if ($r.eval_duration -gt 0) { [math]::Round($r.eval_count / ($r.eval_duration/1e9),1) } else { 0 }
    $proc = ''
    $ps = Invoke-ProcessCaptured $Ollama @('ps') $ProbeTimeoutSec
    foreach ($l in @($ps.Text -split "`r?`n")) {
      if ($l -match [regex]::Escape(($model -replace ':latest$',''))) {
        $mm = [regex]::Match($l,'(\d+%\s*/\s*\d+%\s*CPU/GPU|100%\s*GPU|100%\s*CPU)')
        if ($mm.Success) { $proc = $mm.Value }
      }
    }
    return [pscustomobject]@{ tps=$tps; tokens=$r.eval_count; proc=$proc }
  } catch { return [pscustomobject]@{ tps=0; tokens=0; proc=''; err=$_.Exception.Message } }
}

# =================================================================== MAIN ==
$budget = Get-Budget
Say ""
Say "==== model scout ====  mode: $Mode   $(Get-Date -Format 'yyyy-MM-dd HH:mm')" 'Cyan'
Say ("budget: {0}GB VRAM | {1}GB RAM | {2}GB free disk" -f $budget.VramGB,$budget.RamGB,$budget.DiskFreeGB) 'DarkGray'
$st = Load-State
$logLines = New-Object System.Collections.Generic.List[string]
$logLines.Add("## $(Get-Date -Format 'yyyy-MM-dd HH:mm')  (mode: $Mode)")

# -- manual override: prepare a specific repo --
$pick = $null; $cands = @()
if ($Only) {
  $pick = Parse-Model $Only
  $pick | Add-Member NoteProperty downloads 0 -Force
  $pick | Add-Member NoteProperty ageDays 0 -Force
  $fit = Test-Fit $pick $budget
  $pick | Add-Member NoteProperty verdict $fit.verdict -Force
  $pick | Add-Member NoteProperty sizeGB $fit.sizeGB -Force
  $pick | Add-Member NoteProperty fitWhy $fit.why -Force
  Say "[i] Manual prepare target: $Only ($($fit.verdict))" 'Yellow'
} else {
  Say "[*] Discovering recent GGUF releases from: $($Authors -join ', ')" 'Cyan'
  $cands = Get-Candidates $budget
  $shortlist = $cands | Where-Object { $_.score -ge 0 } | Select-Object -First $TopN
  Say ""
  Say ("  {0,-44} {1,-7} {2,-6} {3}" -f 'MODEL','FIT','~GB','WHY / NOTES') 'Gray'
  foreach ($c in $shortlist) {
    $tag = if ($c.reasoning) { ' [thinking]' } else { '' }
    $line = "  {0,-44} {1,-7} {2,-6} {3}{4}" -f ($c.name), $c.verdict, ($c.sizeGB), $c.fitWhy, $tag
    $col = switch ($c.verdict) { 'Good'{'Green'} 'OK'{'Gray'} default{'DarkGray'} }
    Say $line $col
    $warn = if ($c.parseWarning -and $c.fitWhy -ne $c.parseWarning) { " | $($c.parseWarning)" } else { '' }
    $logLines.Add(("- {0}  | fit:{1} ~{2}GB | dl:{3} | {4}{5}{6}" -f $c.name,$c.verdict,$c.sizeGB,$c.downloads,$c.fitWhy,$tag,$warn))
  }
  # the bar for AUTO-prepare. Thinking-capable models are allowed, but the daily
  # Open WebUI default stays on a responsive non-thinking model. Promote deep
  # models manually when answer quality matters more than startup latency.
  $eligible = $shortlist | Where-Object {
    $_.verdict -eq 'Good' -and $_.family -ne 'other' -and
    $_.downloads -ge 800 -and ($_.ageDays -eq $null -or $_.ageDays -le 60) -and
    ($st.prepared -notcontains $_.id)
  }
  $pick = $eligible | Select-Object -First 1
}

# -- report top of shortlist / decide --
if (-not $pick) {
  Say ""
  Say "[i] No NEW candidate cleared the auto-prepare bar this run." 'Yellow'
  $logLines.Add("- No new pick cleared the bar (need: general, Good fit, known family, >=800 dl, unseen).")
  $topInfo = ($cands | Select-Object -First 1)
  if ($topInfo) { Show-Notify 'Model scout' ("Top candidate: {0} ({1}). Nothing new to auto-install. See model-scout-log.md" -f $topInfo.name,$topInfo.verdict) }
} else {
  Say ""
  Say ("[+] Top pick: {0}   fit={1} (~{2}GB)" -f $pick.name,$pick.verdict,$pick.sizeGB) 'Green'

  if ($Mode -eq 'Scout') {
    Say "    (Scout mode: not pulling. Run -Mode Prepare or AI-ModelScout-Now.bat to install it.)" 'DarkGray'
    $logLines.Add("- TOP PICK (not pulled, Scout mode): $($pick.id)")
    Show-Notify 'Model scout' ("New candidate that fits your 4080: {0}. Run AI-ModelScout-Now.bat to install+ground+benchmark it." -f $pick.name)
  }
  elseif ($pick.sizeGB -and ($budget.DiskFreeGB -lt ($pick.sizeGB + 12))) {
    Say "[!] Low disk (need ~$($pick.sizeGB+12)GB, have $($budget.DiskFreeGB)GB). Skipping pull; notifying instead." 'Yellow'
    $logLines.Add("- SKIPPED pull (low disk): $($pick.id)")
    Show-Notify 'Model scout' ("{0} fits your GPU but disk is low. Free space, then run AI-ModelScout-Now.bat." -f $pick.name)
  }
  else {
    # --- PREPARE: pull -> ground -> benchmark ---
    $repo = $pick.id
    $quant = if ($Quant) { $Quant } else { Get-BestQuant $repo }
    if (-not $quant) { $quant = 'Q4_K_M' }
    Say "[+] Quant chosen for 12GB: $quant" 'Cyan'

    if ($NoPull) {
      Say "    (-NoPull: skipping the actual download)" 'DarkGray'
    } else {
      Say "[+] Pulling hf.co/$repo`:$quant  (this is the big step)..." 'Cyan'
      try {
        [void](Invoke-OllamaChecked "ollama pull hf.co/$repo`:$quant" @('pull', ("hf.co/{0}:{1}" -f $repo,$quant)) $ModelPullTimeoutSec)
      } catch {
        Fail-Scout "prepare failed: $($_.Exception.Message)"
        $logLines.Add("- PREPARE FAILED: $($pick.id) - $($_.Exception.Message)")
        Show-Notify 'Model scout: prepare failed' ("{0}: {1}. See model-scout-log.md" -f $pick.name,$_.Exception.Message)
      }
    }

    $gname = $null
    if (-not $NoPull -and -not $script:ScoutFailed) {
      try {
        $gname = New-GroundedModel $repo $quant $pick
      } catch {
        Fail-Scout "grounded wrapper failed: $($_.Exception.Message)"
        $logLines.Add("- PREPARE FAILED: $($pick.id) - $($_.Exception.Message)")
        Show-Notify 'Model scout: wrapper failed' ("{0}: {1}. See model-scout-log.md" -f $pick.name,$_.Exception.Message)
      }
    }

    # benchmark new vs current default
    $newBench = $null; $baseBench = $null
    if ($gname -and -not $script:ScoutFailed) {
      Say "[+] Benchmarking $gname on your GPU..." 'Cyan'
      $newBench = Measure-Speed $gname
      if ($newBench.err -or $newBench.tps -le 0) {
        Fail-Scout "benchmark failed for $gname`: $($newBench.err)"
        $logLines.Add("- PREPARE FAILED: $gname benchmark failed: $($newBench.err)")
      }
      Say ("    {0}: {1} tok/s  ({2})" -f $gname,$newBench.tps,$newBench.proc) 'Green'
      # Free the new model from RAM BEFORE loading the baseline. Loading two big
      # models at once can exhaust RAM and take down Docker/WSL2 on a 32GB box
      # (this happened on 2026-06-13 with the 21GB Q4 build).
      Stop-OllamaModel $gname
      if (-not $script:ScoutFailed -and (Test-OllamaModelPresent $Baseline)) {
        Say "[+] Benchmarking your current default ($Baseline) for comparison..." 'Cyan'
        $baseBench = Measure-Speed $Baseline
        Say ("    {0}: {1} tok/s  ({2})" -f $Baseline,$baseBench.tps,$baseBench.proc) 'DarkGray'
      }
      Stop-OllamaModel $gname
      Stop-OllamaModel $Baseline
    }

    # verdict + record
    $verdictTxt = 'prepared'
    if ($newBench -and $baseBench -and $baseBench.tps -gt 0) {
      $verdictTxt = if ($newBench.tps -ge $baseBench.tps) { "FASTER than $Baseline ($($newBench.tps) vs $($baseBench.tps) tok/s)" }
                    else { "slower than $Baseline ($($newBench.tps) vs $($baseBench.tps) tok/s)" }
    }
    if ($gname -and -not $script:ScoutFailed) {
      $st.prepared = @($st.prepared + $pick.id | Select-Object -Unique)
      $logLines.Add("- PREPARED: $gname  FROM hf.co/$repo`:$quant")
      $logLines.Add("  - benchmark: $($newBench.tps) tok/s, $($newBench.proc); baseline $Baseline = $($baseBench.tps) tok/s")
      $logLines.Add("  - verdict: $verdictTxt")
      $logLines.Add("  - try it: pick '$gname' in the Open WebUI model dropdown ($Baseline stays default)")

      if ($Mode -eq 'Promote') {
        Say "[+] Promoting $gname to Open WebUI default (old one kept as fallback)..." 'Cyan'
        $originalCompose = $null
        $composeChanged = $false
        try {
          $originalCompose = Get-Content $Compose -Raw
          $txt2 = $originalCompose -replace '(?m)^(\s*-\s*DEFAULT_MODELS=).*$', "`${1}$gname"
          if ($txt2 -notmatch 'DEFAULT_MODEL_PARAMS=\{"stream_response":true\}') {
            $txt2 = $txt2 -replace '(?m)^(\s*-\s*TASK_MODEL=.*)$', "`$1`n      - DEFAULT_MODEL_PARAMS={`"stream_response`":true}"
          }
          if ($txt2 -ne $originalCompose) {
            Set-Content $Compose -Value $txt2 -Encoding utf8
            $composeChanged = $true
            $dbin = Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin'; if (Test-Path $dbin) { $env:PATH="$dbin;$env:PATH" }
            Push-Location $Root
            try {
              [void](Invoke-ProcessChecked 'docker compose up -d open-webui' 'docker' @('compose', 'up', '-d', 'open-webui') $DockerTimeoutSec)
            } finally {
              Pop-Location
            }
            $logLines.Add("  - PROMOTED to Open WebUI DEFAULT_MODELS=$gname")
          }
        } catch {
          if ($composeChanged -and $originalCompose) {
            try {
              Set-Content $Compose -Value $originalCompose -Encoding utf8
              $logLines.Add("  - PROMOTE ROLLED BACK docker-compose.yml after failure")
            } catch {
              $logLines.Add("  - PROMOTE ROLLBACK FAILED: $($_.Exception.Message)")
            }
          }
          Fail-Scout "promote failed: $($_.Exception.Message)"
          $logLines.Add("  - PROMOTE FAILED: $($_.Exception.Message)")
        }
      }

      Show-Notify 'Model scout: new model ready' ("{0}: {1}. Try it in Open WebUI's model picker. See model-scout-log.md" -f $gname,$verdictTxt)
      Say ""
      Say "[OK] $gname is ready. It is NOT your default - pick it in Open WebUI to A/B vs $Baseline." 'Green'
      Say "     Make it default when happy:  pwsh -File ai-model-scout.ps1 -Mode Promote -Only $repo" 'DarkGray'
    }
  }
}

# notes + write log
foreach ($n in $Notes) { $logLines.Add("- note: $n") }
$logLines.Add('')
$existing = if (Test-Path $LogFile) { Get-Content $LogFile -Raw } else { "# localai model-scout log`n`nNewest first. The scout finds/benchmarks new models; it never changes your default unless you run -Mode Promote.`n`n" }
$split = $existing -split "(?<=never changes your default unless you run -Mode Promote.\r?\n\r?\n)", 2
if ($split.Count -eq 2) { $out = $split[0] + (($logLines -join "`n")+"`n") + $split[1] } else { $out = $existing + ($logLines -join "`n") + "`n" }
Set-Content -Path $LogFile -Value $out -Encoding utf8
Save-State $st
Say ""
if ($script:ScoutFailed) {
  Say "[!] Finished with errors. Log: logs\model-scout-log.md" 'Red'
  $exitCode = 1
} else {
  Say "[done] log: logs\model-scout-log.md" 'Green'
}
} finally {
  Release-ModelScoutLock
}
exit $exitCode
