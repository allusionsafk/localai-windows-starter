#requires -Version 7.0
<#
  ai-update.ps1 - Weekly self-updater for the localai stack + Ollama.

  Modes:
    Check  : Detect updates only. Writes the log and shows a notification.
             Changes NOTHING. Good for "what's new?" on demand.
    Apply  : Back up Open WebUI data, then apply the SAFE updates
             (Open WebUI image + Ollama models), prune, log durations.
             Still reports pinned / runtime updates as MANUAL.
    Auto   : (default, used by the weekly task) Apply SAFE updates
             automatically; only NOTIFY for the risky / pinned ones.

  Policy:
    SAFE  (auto)   - Open WebUI image (:main, moving), Ollama model refresh,
                     rebuild of the custom "grounded" models.
    RISKY (notify) - SearXNG + Kokoro images (pinned on purpose; newer SearXNG
                     tags have broken the boot before) and the Ollama / Docker
                     runtimes (they have their own self-updaters).

  NOTE: Output is deliberately plain ASCII. A previous scheduled task on this
  machine was disabled because non-ASCII characters threw errors under the
  older Windows PowerShell 5.1. This script targets pwsh 7 and stays ASCII.
  No admin rights required.
#>
[CmdletBinding()]
param(
  [ValidateSet('Check','Apply','Auto')]
  [string]$Mode = 'Auto',
  [switch]$NoBackup,
  [switch]$Quiet,
  [ValidateRange(30, 7200)]
  [int]$BackupTimeoutSec = 900,
  [ValidateRange(30, 7200)]
  [int]$DockerTimeoutSec = 1800,
  [ValidateRange(30, 14400)]
  [int]$ModelPullTimeoutSec = 3600,
  [ValidateRange(30, 7200)]
  [int]$ModelCreateTimeoutSec = 900,
  [ValidateRange(30, 7200)]
  [int]$ToolUpdateTimeoutSec = 900,
  [ValidateRange(5, 600)]
  [int]$ProbeTimeoutSec = 60
)

# ---------------------------------------------------------------- setup ----
$Root    = $PSScriptRoot
$LogDir  = Join-Path $Root 'logs'
$LogFile = Join-Path $LogDir 'update-log.md'
$State   = Join-Path $LogDir 'state.json'
$Lock    = Join-Path $LogDir '.update.lock'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$dbin = Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin'
if (Test-Path $dbin) { $env:PATH = "$dbin;$env:PATH" }
$Ollama = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
Set-Location $Root

$RunStart = Get-Date
$Findings = New-Object System.Collections.Generic.List[object]   # detected items
$Applied  = New-Object System.Collections.Generic.List[string]   # what changed
$Manual   = New-Object System.Collections.Generic.List[object]   # notify-only items
$Notes    = New-Object System.Collections.Generic.List[string]   # warnings / info

function Say  ([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Note ([string]$m) { $Notes.Add($m); Say "    $m" 'DarkGray' }

# ------------------------------------------------------------- helpers ----
function ConvertTo-Ver([string]$s) {
  if (-not $s) { return $null }
  $m = [regex]::Match($s.Trim().TrimStart('v','V'), '^\d+(\.\d+){0,3}')
  if (-not $m.Success) { return $null }
  try { return [version]$m.Value } catch { return $null }
}
function Test-Newer([string]$current, [string]$latest) {
  $c = ConvertTo-Ver $current; $l = ConvertTo-Ver $latest
  if ($c -and $l) { return ($l -gt $c) }
  return ($latest -and $current -and ($latest -ne $current))
}
function Load-State {
  $s = $null
  if (Test-Path $State) {
    try { $s = Get-Content $State -Raw | ConvertFrom-Json -AsHashtable } catch { }
  }
  if ($null -eq $s) { $s = @{} }
  if (-not $s.ContainsKey('manualNotified') -or $null -eq $s['manualNotified']) { $s['manualNotified'] = @{} }
  if (-not $s.ContainsKey('lastApplySeconds')) { $s['lastApplySeconds'] = 0 }
  return $s
}
function Save-State($s) {
  try { $s | ConvertTo-Json -Depth 6 | Set-Content $State -Encoding utf8 } catch { }
}
function HumanTime([double]$sec) {
  if ($sec -le 0) { return 'n/a' }
  $t = [TimeSpan]::FromSeconds([math]::Round($sec))
  if ($t.TotalMinutes -lt 1) { return ('{0}s' -f $t.Seconds) }
  return ('{0}m {1}s' -f [int]$t.TotalMinutes, $t.Seconds)
}
. (Join-Path $Root 'ai-common.ps1')   # shared Invoke-AiProcess (was inlined below)
function Invoke-ProcessCaptured([string]$FilePath, [string[]]$ArgumentList = @(), [int]$TimeoutSec = 300, [string]$WorkingDirectory = $Root) {
  return Invoke-AiProcess $FilePath $ArgumentList $TimeoutSec $WorkingDirectory
}
function Invoke-ProcessChecked([string]$label, [string]$FilePath, [string[]]$ArgumentList = @(), [int]$TimeoutSec = 300) {
  $r = Invoke-ProcessCaptured $FilePath $ArgumentList $TimeoutSec
  if ($r.Code -ne 0) {
    $detail = if ($r.Text) { " - $($r.Text)" } else { '' }
    throw "$label failed (exit $($r.Code))$detail"
  }
  return $r
}

function Get-ImageLocalDigest([string]$ref) {
  $r = Invoke-ProcessCaptured 'docker' @('image', 'inspect', $ref, '--format', '{{index .RepoDigests 0}}') $ProbeTimeoutSec
  if ($r.Code -ne 0 -or -not $r.Text) { return $null }
  return ((($r.Text -split "`r?`n") | Select-Object -First 1) -split '@')[-1].Trim()
}
function Get-ImageRemoteDigest([string]$ref) {
  try {
    $r = Invoke-ProcessCaptured 'docker' @('buildx', 'imagetools', 'inspect', $ref, '--format', '{{.Manifest.Digest}}') $ProbeTimeoutSec
    if ($r.Code -eq 0 -and $r.Text) { return ($r.Text -split "`r?`n" | Select-Object -First 1).Trim() }
  } catch { }
  return $null
}
function Get-OllamaId([string]$name) {
  $want = $name.ToLower()
  $r = Invoke-ProcessCaptured $Ollama @('list') $ProbeTimeoutSec
  if ($r.Code -ne 0 -or -not $r.Text) { return $null }
  $lines = $r.Text -split "`r?`n"
  foreach ($l in $lines) {
    $cols = ($l -split '\s{2,}')
    if ($cols.Count -lt 2) { continue }
    $n = $cols[0].ToLower()
    if ($n -eq $want -or $n -eq "$want`:latest") { return $cols[1].Trim() }
  }
  return $null
}

# Best-effort desktop notification. No external module is installed on the fly
# (auto-installing modules in an unattended task is exactly how things break);
# we use BurntToast only if you already have it, else a tray balloon, else log.
function Show-Notify([string]$title, [string]$message) {
  if ($Quiet) { return }
  try {
    if (Get-Module -ListAvailable -Name BurntToast) {
      Import-Module BurntToast -ErrorAction Stop
      New-BurntToastNotification -Text $title, $message -ErrorAction Stop
      return
    }
  } catch { }
  try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $ni = New-Object System.Windows.Forms.NotifyIcon
    $ni.Icon = [System.Drawing.SystemIcons]::Information
    $ni.Visible = $true
    $ni.BalloonTipTitle = $title
    $ni.BalloonTipText = $message
    $ni.ShowBalloonTip(10000)
    Start-Sleep -Seconds 6
    $ni.Dispose()
  } catch {
    Note "notification suppressed (no UI): $title - $message"
  }
}

# ------------------------------------------------------------- lock --------
$haveLock = $false
try {
  $fs = [System.IO.File]::Open($Lock, 'OpenOrCreate', 'ReadWrite', 'None')
  $haveLock = $true
} catch {
  Say "[!] Another update run is in progress (lock held). Exiting." 'Yellow'
  return
}

try {
  $st = Load-State
  Say ""
  Say "==== localai updater ====  mode: $Mode   $(Get-Date -Format 'yyyy-MM-dd HH:mm')" 'Cyan'

  # ----------------------------------------------------- docker present? --
  $dockerUp = $false
  try { (& docker info --format '{{.ServerVersion}}') 2>$null | Out-Null; $dockerUp = ($LASTEXITCODE -eq 0) } catch { }
  if (-not $dockerUp) { Note "Docker is not running - skipping container checks/updates." }

  $ollamaOk = Test-Path $Ollama
  if (-not $ollamaOk) { Note "Ollama not found at $Ollama - skipping model checks/updates." }

  # parse the pinned tags straight from the compose file (single source of truth)
  $searxngTag = 'unknown'; $kokoroTag = 'unknown'
  try {
    $composeText = Get-Content (Join-Path $Root 'docker-compose.yml') -Raw
    $m1 = [regex]::Match($composeText, 'searxng/searxng:([^\s"'']+)')
    $m2 = [regex]::Match($composeText, 'kokoro-fastapi-cpu:([^\s"'']+)')
    if ($m1.Success) { $searxngTag = $m1.Groups[1].Value }
    if ($m2.Success) { $kokoroTag  = $m2.Groups[1].Value }
  } catch { }

  # ============================================ DETECT: safe (Open WebUI) ==
  $owNeedsUpdate = $false
  $owLocal = $null; $owRemote = $null
  if ($dockerUp) {
    Say "[*] Checking Open WebUI image..." 'Cyan'
    $owLocal  = Get-ImageLocalDigest  'ghcr.io/open-webui/open-webui:main'
    $owRemote = Get-ImageRemoteDigest 'ghcr.io/open-webui/open-webui:main'
    if ($owRemote -and $owLocal -and ($owRemote -ne $owLocal)) {
      $owNeedsUpdate = $true
      Say "    update available" 'Green'
    } elseif (-not $owRemote) {
      Note "could not reach registry for Open WebUI - will refresh on apply anyway."
      $owNeedsUpdate = $true   # let the pull decide
    } else {
      Say "    up to date" 'DarkGray'
    }
  }

  # ============================================ DETECT: risky / notify ====
  # Ollama runtime
  if ($ollamaOk) {
    Say "[*] Checking Ollama runtime..." 'Cyan'
    $curOllama = $null
    try { $curOllama = [regex]::Match(((& $Ollama --version) 2>&1), '\d+\.\d+\.\d+').Value } catch { }
    try {
      $latestOllama = (Invoke-RestMethod 'https://api.github.com/repos/ollama/ollama/releases/latest' -Headers @{ 'User-Agent' = 'localai-updater' } -TimeoutSec 20).tag_name
      if (Test-Newer $curOllama $latestOllama) {
        $Manual.Add([pscustomobject]@{ name='Ollama runtime'; key='ollama'; cur=$curOllama; latest=$latestOllama;
          how='Ollama self-updates; or get it from https://ollama.com/download , then restart Ollama.' })
        Say "    $latestOllama available (you have $curOllama)" 'Yellow'
      } else { Say "    up to date ($curOllama)" 'DarkGray' }
    } catch { Note "could not check Ollama releases (offline?)." }
  }

  # SearXNG (pinned)
  if ($dockerUp -and $searxngTag -ne 'unknown') {
    Say "[*] Checking SearXNG (pinned)..." 'Cyan'
    try {
      $tags = (Invoke-RestMethod 'https://hub.docker.com/v2/repositories/searxng/searxng/tags?page_size=25&ordering=last_updated' -TimeoutSec 20).results.name
      $newest = $tags | Where-Object { $_ -match '^\d{4}\.\d+\.\d+' } | Select-Object -First 1
      if ($newest -and (Test-Newer $searxngTag $newest)) {
        $Manual.Add([pscustomobject]@{ name='SearXNG'; key='searxng'; cur=$searxngTag; latest=$newest;
          how='PINNED on purpose (newer tags have broken the boot). Only if you will test it: edit docker-compose.yml searxng image tag, run ai-update.ps1 -Mode Apply, then confirm http://localhost:8080 loads.' })
        Say "    $newest available (pinned at $searxngTag)" 'Yellow'
      } else { Say "    no newer tag (pinned at $searxngTag)" 'DarkGray' }
    } catch { Note "could not check SearXNG tags (offline?)." }
  }

  # Kokoro (pinned)
  if ($dockerUp -and $kokoroTag -ne 'unknown') {
    Say "[*] Checking Kokoro TTS (pinned)..." 'Cyan'
    try {
      $latestKokoro = (Invoke-RestMethod 'https://api.github.com/repos/remsky/Kokoro-FastAPI/releases/latest' -Headers @{ 'User-Agent' = 'localai-updater' } -TimeoutSec 20).tag_name
      if (Test-Newer $kokoroTag $latestKokoro) {
        $Manual.Add([pscustomobject]@{ name='Kokoro TTS'; key='kokoro'; cur=$kokoroTag; latest=$latestKokoro;
          how='PINNED. To update: edit docker-compose.yml kokoro image tag to this version, run ai-update.ps1 -Mode Apply, then test voice playback in a chat.' })
        Say "    $latestKokoro available (pinned at $kokoroTag)" 'Yellow'
      } else { Say "    up to date ($kokoroTag)" 'DarkGray' }
    } catch { Note "could not check Kokoro releases (offline?)." }
  }

  # ================================================================ ACT ===
  $applyRequested = ($Mode -eq 'Apply') -or ($Mode -eq 'Auto')
  $didApply = $applyRequested
  $backupFile = $null
  $applyFailed = $false

  if ($didApply) {
    # ---- backup first (do not mutate a working stack without one) --------
    if (-not $NoBackup -and $dockerUp) {
      Say "[+] Backing up Open WebUI data..." 'Cyan'
      try {
        $backupOuterTimeout = $BackupTimeoutSec + 30
        $backupRun = Invoke-AiLocalai @('backup', '--timeout-sec', "$BackupTimeoutSec") $backupOuterTimeout $Root
        if ($backupRun.Code -ne 0) {
          $detail = if ($backupRun.Text) { " - $($backupRun.Text)" } else { '' }
          throw "localai backup failed (exit $($backupRun.Code))$detail"
        }
        $bk = Get-ChildItem (Join-Path $Root 'backups') -Filter 'open-webui-*.tar.gz' -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $bk) { throw 'localai backup completed but no open-webui backup file was found' }
        if ($bk.Length -le 0) { throw "backup file is empty: $($bk.Name)" }
        $backupFile = "$($bk.Name) ({0:N1} MB)" -f ($bk.Length / 1MB)
      } catch {
        Say "[!] Backup failed - skipping apply to stay safe. ($($_.Exception.Message))" 'Red'
        $Notes.Add("APPLY SKIPPED: backup failed - $($_.Exception.Message)")
        $didApply = $false
        $applyFailed = $true
      }
    }
  }

  if ($didApply) {
    # ---- Docker safe updates (pinned images are a no-op on pull) ---------
    if ($dockerUp) {
      try {
        Say "[+] Pulling images (pinned tags stay put)..." 'Cyan'
        [void](Invoke-ProcessChecked 'docker compose pull' 'docker' @('compose', 'pull') $DockerTimeoutSec)
        Say "[+] Recreating changed containers..." 'Cyan'
        [void](Invoke-ProcessChecked 'docker compose up -d' 'docker' @('compose', 'up', '-d') $DockerTimeoutSec)
        Say "[+] Pruning dangling images..." 'Cyan'
        [void](Invoke-ProcessChecked 'docker image prune' 'docker' @('image', 'prune', '-f') $ProbeTimeoutSec)
        $owAfter = Get-ImageLocalDigest 'ghcr.io/open-webui/open-webui:main'
        if ($owLocal -and $owAfter -and ($owAfter -ne $owLocal)) {
          $Applied.Add("Open WebUI image updated ($($owLocal.Substring(0,19))... -> $($owAfter.Substring(0,19))...)")
        } elseif (-not $owLocal -and $owAfter) {
          $Applied.Add("Open WebUI image present ($($owAfter.Substring(0,19))...)")
        }
      } catch {
        Say "[!] Docker safe update failed - skipping the rest of apply. ($($_.Exception.Message))" 'Red'
        $Notes.Add("APPLY SKIPPED: Docker safe update failed - $($_.Exception.Message)")
        $didApply = $false
        $applyFailed = $true
      }
    }

    # ---- Ollama models: refresh bases, rebuild grounded if base changed --
    if ($didApply -and $ollamaOk) {
      Say "[+] Refreshing Ollama models (incremental)..." 'Cyan'
      $models = @(
        @{ base='qwen2.5:14b';                                                      grounded='qwen2.5-grounded'; file='qwen-grounded.Modelfile' },
        @{ base='hf.co/unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF:UD-Q4_K_XL';        grounded='qwen3-grounded';   file='qwen3-grounded.Modelfile' },
        @{ base='hf.co/unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q3_K_XL';                    grounded='qwen3.6-35b-a3b-grounded'; file='scout-qwen3.6-35b-a3b.Modelfile' },
        @{ base='qwen2.5-coder:14b';                                                grounded=$null;              file=$null },
        @{ base='qwen3-coder:30b';                                                   grounded=$null;              file=$null },
        @{ base='qwen2.5vl:7b';                                                      grounded=$null;              file=$null },
        @{ base='nomic-embed-text';                                                 grounded=$null;              file=$null }
      )
      foreach ($mo in $models) {
        $pre = Get-OllamaId $mo.base
        Say "    pull $($mo.base)" 'DarkGray'
        $pull = Invoke-ProcessCaptured $Ollama @('pull', $mo.base) $ModelPullTimeoutSec
        if ($pull.Code -ne 0) {
          Note "model pull failed for $($mo.base) (exit $($pull.Code)); skipping any wrapper rebuild. $($pull.Text)"
          $applyFailed = $true
          continue
        }
        $post = Get-OllamaId $mo.base
        $changed = ($pre -ne $post)
        if ($changed) { $Applied.Add("model $($mo.base): $pre -> $post") }
        $wrappers = @()
        if ($mo.grounded) {
          $wrappers += @{ grounded = $mo.grounded; file = $mo.file }
        }
        if ($mo.base -eq 'hf.co/unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q3_K_XL') {
          $wrappers += @{ grounded = 'qwen3.6-thinklight-grounded'; file = 'qwen3.6-thinklight-grounded.Modelfile' }
        }

        foreach ($wrapper in $wrappers) {
          $needBuild = $changed -or (-not (Get-OllamaId $wrapper.grounded))
          if ($needBuild) {
            $mf = Join-Path $Root $wrapper.file
            if (Test-Path $mf) {
              Say "    rebuild $($wrapper.grounded)" 'DarkGray'
              $create = Invoke-ProcessCaptured $Ollama @('create', $wrapper.grounded, '-f', $mf) $ModelCreateTimeoutSec
              if ($create.Code -eq 0) {
                $Applied.Add("rebuilt $($wrapper.grounded)")
              } else {
                Note "rebuild failed for $($wrapper.grounded) (exit $($create.Code)). $($create.Text)"
                $applyFailed = $true
              }
            } else { Note "missing $($wrapper.file) - cannot rebuild $($wrapper.grounded)." }
          }
        }
      }
      $aliasScript = Join-Path $Root 'ai-model-aliases.ps1'
      if (Test-Path $aliasScript) {
        Say "    refresh purpose-based dropdown aliases" 'DarkGray'
        $alias = Invoke-ProcessCaptured 'pwsh' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $aliasScript) $ProbeTimeoutSec
        if ($alias.Code -ne 0) {
          Note "model alias refresh failed. $($alias.Text)"
          $applyFailed = $true
        }
      }
    }

    # ---- Terminal AI tooling: Aider via uv (best-effort) ---------------
    $uv = $null
    $uvCmd = Get-Command 'uv' -ErrorAction SilentlyContinue
    if ($uvCmd) { $uv = $uvCmd.Source }
    if (-not $uv) {
      $uvCandidates = @(
        (Join-Path $env:APPDATA 'Python\Python313\Scripts\uv.exe'),
        (Join-Path $env:APPDATA 'Python\Python312\Scripts\uv.exe'),
        (Join-Path $env:APPDATA 'Python\Python311\Scripts\uv.exe'),
        (Join-Path $env:APPDATA 'Python\Python310\Scripts\uv.exe'),
        (Join-Path $env:APPDATA 'Python\Python39\Scripts\uv.exe'),
        (Join-Path $env:APPDATA 'Python\Python314\Scripts\uv.exe')
      )
      $uv = $uvCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
      if ($uv -and $uv -match 'Python314') {
        Note "Using uv.exe from Python 3.14 as a last-resort fallback; PATH or a stable Python Scripts path is preferred."
      }
    }
    if ($didApply) {
      if ($uv) {
        Say "[+] Refreshing terminal AI tools (Aider)..." 'Cyan'
        $beforeAider = $null
        try {
          $before = Invoke-ProcessCaptured 'aider' @('--version') 30
          if ($before.Code -eq 0 -and $before.Text) { $beforeAider = ($before.Text -split "`r?`n" | Select-Object -First 1).Trim() }
        } catch { }
        $uvUpgrade = Invoke-ProcessCaptured $uv @('tool', 'upgrade', 'aider-chat') $ToolUpdateTimeoutSec
        if ($uvUpgrade.Code -eq 0) {
          $afterAider = $null
          try {
            $after = Invoke-ProcessCaptured 'aider' @('--version') 30
            if ($after.Code -eq 0 -and $after.Text) { $afterAider = ($after.Text -split "`r?`n" | Select-Object -First 1).Trim() }
          } catch { }
          if ($afterAider -and $afterAider -ne $beforeAider) {
            $Applied.Add("Aider updated ($beforeAider -> $afterAider)")
          } else {
            Note "Aider already current ($afterAider)."
          }
        } else {
          Note "Aider update failed; leaving existing terminal AI tool in place. $($uvUpgrade.Text)"
        }
      } else {
        Note "uv.exe not found - skipping Aider terminal-tool update."
      }
    }
    if ($didApply -and -not $applyFailed) { $st.lastApply = (Get-Date).ToString('o') }
  }

  # ============================================================ NOTIFY ====
  $elapsed = ((Get-Date) - $RunStart).TotalSeconds
  if ($didApply -and -not $applyFailed) { $st.lastApplySeconds = [math]::Round($elapsed) }

  # decide which manual items are NEW (avoid nagging weekly about the same ver)
  $notified = $st['manualNotified']
  if ($null -eq $notified) { $notified = @{} }
  $newManual = @()
  foreach ($mi in $Manual) {
    if (-not $notified.ContainsKey($mi.key) -or $notified[$mi.key] -ne $mi.latest) { $newManual += $mi }
    $notified[$mi.key] = $mi.latest
  }
  $st['manualNotified'] = $notified
  $st.lastCheck = (Get-Date).ToString('o')
  Save-State $st

  # build toast text
  $toastTitle = 'localai updater'
  $parts = @()
  if ($applyFailed)         { $parts += 'Apply failed or was skipped' }
  elseif ($Applied.Count -gt 0) { $parts += "Updated: $($Applied.Count) item(s)" }
  elseif ($didApply)        { $parts += 'Everything already up to date' }
  if ($Manual.Count -gt 0)  { $parts += ("Manual: " + (($Manual | ForEach-Object { "$($_.name) $($_.latest)" }) -join ', ')) }
  $parts += "Took $(HumanTime $elapsed). See update-log.md"
  $toastMsg = $parts -join "`n"

  # notify if: applied something, apply failed, OR there is a NEW manual item, OR explicit Check
  if (($Applied.Count -gt 0) -or $applyFailed -or ($newManual.Count -gt 0) -or ($Mode -eq 'Check')) {
    if ($Mode -eq 'Check' -and $Applied.Count -eq 0 -and -not $applyFailed) {
      $estimate = if ($st.lastApplySeconds -gt 0) { "~$(HumanTime $st.lastApplySeconds) based on last run" } else { 'a few minutes' }
      $chk = @()
      if ($owNeedsUpdate) { $chk += 'Open WebUI update ready' } else { $chk += 'Open WebUI up to date' }
      $chk += 'models: refreshed on apply (incremental)'
      if ($Manual.Count -gt 0) { $chk += ('manual: ' + (($Manual | ForEach-Object { "$($_.name) $($_.latest)" }) -join ', ')) }
      $chk += "Apply now: run ai-update.ps1 -Mode Apply (est. $estimate)"
      $toastMsg = $chk -join "`n"
    }
    Show-Notify $toastTitle $toastMsg
  }

  # ============================================================== LOG =====
  $hdr = "## $(Get-Date -Format 'yyyy-MM-dd HH:mm')  (mode: $Mode)"
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add($hdr)
  if ($applyFailed) {
    $lines.Add('- Apply status: FAILED or skipped before completion. See notes below.')
  }
  if ($Applied.Count -gt 0) {
    $lines.Add('**Applied:**')
    foreach ($a in $Applied) { $lines.Add("- $a") }
  } elseif ($didApply) {
    $lines.Add('- No changes (everything was already current).')
  } elseif ($applyRequested) {
    $lines.Add('- Apply requested, but no safe updates were completed.')
  } else {
    $lines.Add('- Check only - nothing was changed.')
    if ($owNeedsUpdate) { $lines.Add('- Open WebUI: update available (apply with ai-update.ps1 -Mode Apply).') }
    else { $lines.Add('- Open WebUI: up to date.') }
  }
  if ($Manual.Count -gt 0) {
    $lines.Add('**Manual (notify-only):**')
    foreach ($mi in $Manual) {
      $tag = if ($newManual -contains $mi) { 'NEW' } else { 'seen' }
      $lines.Add("- [$tag] $($mi.name): $($mi.latest) available (you have $($mi.cur)). $($mi.how)")
    }
  }
  if ($backupFile) { $lines.Add("- Backup: $backupFile") }
  if ($Notes.Count -gt 0) { foreach ($n in $Notes) { $lines.Add("- note: $n") } }
  $lines.Add("- Duration: $(HumanTime $elapsed)")
  $lines.Add('')

  $existing = if (Test-Path $LogFile) { Get-Content $LogFile -Raw } else { "# localai update log`n`nNewest first.`n`n" }
  # insert newest section right after the title block
  $split = $existing -split "(?<=Newest first.\r?\n\r?\n)", 2
  if ($split.Count -eq 2) { $out = $split[0] + (($lines -join "`n") + "`n") + $split[1] }
  else { $out = $existing + ($lines -join "`n") + "`n" }
  Set-Content -Path $LogFile -Value $out -Encoding utf8

  Say ""
  if ($applyFailed) {
    Say "[!] Finished with apply errors in $(HumanTime $elapsed). Log: logs\update-log.md" 'Red'
  } else {
    Say "[OK] Done in $(HumanTime $elapsed). Log: logs\update-log.md" 'Green'
  }
  if ($Manual.Count -gt 0) { Say "[i] $($Manual.Count) manual update(s) to review in the log." 'Yellow' }
  if ($applyFailed) { exit 1 }
}
finally {
  if ($haveLock) { try { $fs.Close(); Remove-Item $Lock -Force -ErrorAction SilentlyContinue } catch { } }
}
