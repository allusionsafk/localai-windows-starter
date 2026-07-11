#requires -Version 7.0
<#
  ai-selftest.ps1 - End-to-end local AI smoke test.

  This is heavier than `localai health`: it runs the public ai-* commands, verifies
  web/vision/code dry-run behavior, then re-warms the fast default model.
  Image generation is optional because it starts ComfyUI and uses more VRAM.
#>
[CmdletBinding()]
param(
  [switch]$SkipWeb,
  [switch]$SkipVision,
  [switch]$SkipCode,
  [switch]$SkipApplyEdit,
  [switch]$IncludeImage,
  [switch]$NoWarm
)

$ErrorActionPreference = 'SilentlyContinue'
$Root = $PSScriptRoot
$Ollama = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
$Ok = 0
$Warn = 0
$Fail = 0

function Line($status, $name, $detail) {
  $color = switch ($status) {
    'OK' { 'Green' }
    'WARN' { 'Yellow' }
    'FAIL' { 'Red' }
    default { 'Gray' }
  }
  if ($status -eq 'OK') { $script:Ok++ }
  elseif ($status -eq 'WARN') { $script:Warn++ }
  elseif ($status -eq 'FAIL') { $script:Fail++ }
  Write-Host ("[{0}] {1,-22} {2}" -f $status, $name, $detail) -ForegroundColor $color
}

function Require-Command($name) {
  $cmd = Get-Command $name -ErrorAction SilentlyContinue
  if ($cmd) {
    Line 'OK' $name $cmd.Source
    return $true
  }
  Line 'FAIL' $name 'not found on PATH'
  return $false
}

. (Join-Path $Root 'ai-common.ps1')   # shared Invoke-AiProcess (was inlined below)
function Invoke-ProcessCaptured([string]$FilePath, [string[]]$ArgumentList = @(), [int]$TimeoutSec = 300, [string]$WorkingDirectory = $Root) {
  # .cmd/.bat need a cmd.exe host; everything else goes straight to the shared runner.
  $resolved = Resolve-AiCommandPath $FilePath
  if ($resolved -match '\.(cmd|bat)$') {
    $shell = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
    return Invoke-AiProcess $shell (@('/d', '/c', $resolved) + @($ArgumentList)) $TimeoutSec $WorkingDirectory
  }
  return Invoke-AiProcess $FilePath $ArgumentList $TimeoutSec $WorkingDirectory
}

function New-TestImage([string]$Path) {
  Add-Type -AssemblyName System.Drawing
  $bmp = [System.Drawing.Bitmap]::new(480, 260)
  try {
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
      $g.Clear([System.Drawing.Color]::FromArgb(245, 248, 252))
      $font = [System.Drawing.Font]::new('Arial', 28, [System.Drawing.FontStyle]::Bold)
      $brush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(20, 40, 70))
      $accent = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(42, 133, 255))
      try {
        $g.FillRectangle($accent, 32, 32, 86, 86)
        $g.DrawString('LOCAL AI OK', $font, $brush, 140, 50)
        $g.DrawString('vision self-test', [System.Drawing.Font]::new('Arial', 18), $brush, 140, 105)
      } finally {
        $font.Dispose()
        $brush.Dispose()
        $accent.Dispose()
      }
    } finally {
      $g.Dispose()
    }
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
  } finally {
    $bmp.Dispose()
  }
}

Write-Host "==== localai self-test ====  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

Set-Location $Root

$health = Invoke-AiLocalai @('health') 180 $Root
if ($health.Code -eq 0) { Line 'OK' 'stack health' 'localai health passed' }
else { Line 'FAIL' 'stack health' $health.Text }

$perfScript = Join-Path $Root 'ai-perf.ps1'
if (Test-Path -LiteralPath $perfScript) {
  $perf = Invoke-ProcessCaptured 'pwsh' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $perfScript, '-Strict') 120
  if ($perf.Code -eq 0) { Line 'OK' 'perf guard' 'ai-perf.ps1 -Strict passed' }
  else { Line 'FAIL' 'perf guard' $perf.Text }
} else {
  Line 'WARN' 'perf guard' 'ai-perf.ps1 missing'
}

$needed = @('ai-models','ai-chat','ai-deepchat','ai-code','ai-web','ai-vision','ai-image','ai-start','ai-game-mode','aider')
foreach ($n in $needed) { [void](Require-Command $n) }

$models = Invoke-ProcessCaptured 'ai-models' @() 60
if ($models.Code -eq 0 -and $models.Text -match 'Chat\s+qwen2\.5-grounded' -and $models.Text -match 'DeepChat\s+deep-thinking-qwen3\.6') {
  Line 'OK' 'ai-models' 'fast/deep terminal map present'
} else {
  Line 'FAIL' 'ai-models' $models.Text
}

$chat = Invoke-ProcessCaptured 'ai-chat' @('-Prompt', 'Answer exactly: terminal-chat-ok') 180
if ($chat.Code -eq 0 -and $chat.Text.Length -gt 0) { Line 'OK' 'ai-chat' ($chat.Text -replace '\s+',' ') }
else { Line 'FAIL' 'ai-chat' $chat.Text }

if (-not $SkipWeb) {
  $web = Invoke-ProcessCaptured 'ai-web' @('-Prompt', 'What is Open WebUI? Answer in one short sentence using local search results.') 300
  if ($web.Code -eq 0 -and $web.Text.Length -gt 0) { Line 'OK' 'ai-web' (($web.Text -replace '\s+',' ').Substring(0, [Math]::Min(120, ($web.Text -replace '\s+',' ').Length))) }
  else { Line 'FAIL' 'ai-web' $web.Text }
} else {
  Line 'WARN' 'ai-web' 'skipped'
}

if (-not $SkipVision) {
  $img = Join-Path $env:TEMP 'localai-vision-selftest.png'
  try {
    New-TestImage $img
    $vision = Invoke-ProcessCaptured 'ai-vision' @('-ImagePath', $img, '-Prompt', 'In one sentence, describe the image.') 300
    if ($vision.Code -eq 0 -and $vision.Text.Length -gt 0) { Line 'OK' 'ai-vision' (($vision.Text -replace '\s+',' ').Substring(0, [Math]::Min(120, ($vision.Text -replace '\s+',' ').Length))) }
    else { Line 'FAIL' 'ai-vision' $vision.Text }
  } catch {
    Line 'FAIL' 'ai-vision' $_.Exception.Message
  } finally {
    Remove-Item -LiteralPath $img -Force -ErrorAction SilentlyContinue
  }
} else {
  Line 'WARN' 'ai-vision' 'skipped'
}

if (-not $SkipCode) {
  $proj = Join-Path $env:TEMP 'localai-code-dryrun-selftest'
  Remove-Item -LiteralPath $proj -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $proj | Out-Null
  Set-Content -Path (Join-Path $proj 'check.txt') -Encoding ascii -Value 'local ai code dry-run fixture'
  Push-Location $proj
  try { git init | Out-Null } catch { }
  Pop-Location
  $before = (Get-FileHash -LiteralPath (Join-Path $proj 'check.txt') -Algorithm SHA256).Hash
  $code = Invoke-ProcessCaptured 'ai-code' @('-Project', $proj, '-Files', 'check.txt', '-Prompt', 'Do not change any files. In one sentence, say what check.txt is for.', '-DryRun', '-YesAlways') 420
  $after = (Get-FileHash -LiteralPath (Join-Path $proj 'check.txt') -Algorithm SHA256).Hash
  if ($code.Code -eq 0 -and $before -eq $after) { Line 'OK' 'ai-code dry-run' 'Aider ran and fixture file hash stayed unchanged' }
  elseif ($before -ne $after) { Line 'FAIL' 'ai-code dry-run' 'fixture file changed despite dry-run' }
  else { Line 'FAIL' 'ai-code dry-run' $code.Text }
  Remove-Item -LiteralPath $proj -Recurse -Force -ErrorAction SilentlyContinue

  if (-not $SkipApplyEdit) {
    $editProj = Join-Path $env:TEMP 'localai-code-apply-selftest'
    Remove-Item -LiteralPath $editProj -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $editProj | Out-Null
    $target = Join-Path $editProj 'check.txt'
    Set-Content -Path $target -Encoding ascii -Value 'before local ai edit'
    Push-Location $editProj
    try { git init | Out-Null } catch { }
    Pop-Location
    $auditLog = Join-Path $Root 'logs\terminal-ai-edits.jsonl'
    $auditBeforeCount = 0
    if (Test-Path $auditLog) {
      try { $auditBeforeCount = @((Get-Content -LiteralPath $auditLog)).Count } catch { $auditBeforeCount = 0 }
    }
    $applyPrompt = 'Replace the entire contents of check.txt with exactly: local ai code apply ok'
    $apply = Invoke-ProcessCaptured 'ai-code' @('-Project', $editProj, '-Files', 'check.txt', '-Prompt', $applyPrompt, '-YesAlways') 600
    $content = ''
    try { $content = (Get-Content -LiteralPath $target -Raw).Trim() } catch { }
    $auditEntry = $null
    if (Test-Path $auditLog) {
      try {
        $newAuditLines = @(Get-Content -LiteralPath $auditLog | Select-Object -Skip $auditBeforeCount)
        foreach ($line in $newAuditLines) {
          if (-not $line.Trim()) { continue }
          $entry = $line | ConvertFrom-Json
          if ($entry.project -eq $editProj -and -not $entry.dryRun) { $auditEntry = $entry }
        }
      } catch { }
    }
    if ($apply.Code -eq 0 -and $content -eq 'local ai code apply ok') {
      Line 'OK' 'ai-code apply' 'Aider edited a disposable temp repo correctly'
      if ($auditEntry -and $auditEntry.exitCode -eq 0 -and @($auditEntry.before).Count -gt 0 -and @($auditEntry.after).Count -gt 0) {
        Line 'OK' 'ai-code audit' 'terminal-ai-edits.jsonl recorded the temp edit'
      } else {
        Line 'FAIL' 'ai-code audit' 'missing or incomplete terminal edit audit entry'
      }
    } elseif ($apply.Code -eq 0) {
      Line 'FAIL' 'ai-code apply' "unexpected file content: $content"
    } else {
      Line 'FAIL' 'ai-code apply' $apply.Text
    }
    Remove-Item -LiteralPath $editProj -Recurse -Force -ErrorAction SilentlyContinue
  } else {
    Line 'WARN' 'ai-code apply' 'skipped'
  }
} else {
  Line 'WARN' 'ai-code dry-run' 'skipped'
}

if ($IncludeImage) {
  $image = Invoke-ProcessCaptured 'ai-image' @('-Prompt', 'a simple matte black cube on a white table, studio light', '-Width', '512', '-Height', '512', '-Steps', '1', '-NoOpen') 900
  if ($image.Code -eq 0) {
    $saved = [regex]::Match($image.Text, '(?m)\[\+\]\s+Saved:\s+(.+)$')
    if ($saved.Success) { Line 'OK' 'ai-image' ("saved " + $saved.Groups[1].Value.Trim()) }
    else { Line 'OK' 'ai-image' 'generation command completed' }
  }
  else { Line 'FAIL' 'ai-image' $image.Text }
} else {
  $launcher = Join-Path $env:USERPROFILE 'imageai\Start-Image-Studio.bat'
  if (Test-Path $launcher) { Line 'OK' 'ai-image' 'launcher present; generation skipped unless -IncludeImage is used' }
  else { Line 'WARN' 'ai-image' 'launcher missing' }
}

if (-not $NoWarm) {
  $warm = Invoke-ProcessCaptured 'pwsh' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'ai-warm.ps1'), '-RequireOllama') 300
  if ($warm.Code -eq 0) { Line 'OK' 'rewarm default' ($warm.Text -replace '\s+',' ') }
  else { Line 'WARN' 'rewarm default' $warm.Text }
}

try {
  $ps = & $Ollama ps
  $loaded = $ps | Select-String -SimpleMatch 'qwen2.5-grounded' | Select-Object -First 1
  if ($loaded) { Line 'OK' 'final warm model' $loaded.Line.Trim() }
  else { Line 'WARN' 'final warm model' 'qwen2.5-grounded not loaded' }
} catch {
  Line 'WARN' 'final warm model' 'ollama ps failed'
}

Write-Host ("`nSelf-test summary: {0} OK, {1} WARN, {2} FAIL" -f $Ok, $Warn, $Fail)
if ($Fail -gt 0) { exit 1 }
exit 0
