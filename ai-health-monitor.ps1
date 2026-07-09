#requires -Version 7.0
<#
  ai-health-monitor.ps1 - Quiet monitor/self-heal wrapper around ai-health.ps1
  and ai-perf.ps1.

  Healthy runs are logged only. If health or performance drift checks fail,
  optionally runs Start-LocalAI.bat /noopen once, checks again, and sends a
  Windows notification only if still failed or if a repair was needed. Warnings
  from ai-health.ps1 are not failures; ai-perf.ps1 runs in -Strict mode so
  context/GPU drift is treated as actionable.
#>
[CmdletBinding()]
param(
  [switch]$Repair,
  [switch]$NotifyOnSuccess,
  [ValidateRange(5, 3600)]
  [int]$HealthTimeoutSec = 300,
  [ValidateRange(10, 7200)]
  [int]$RepairTimeoutSec = 900
)

$ErrorActionPreference = 'SilentlyContinue'
$Root = $PSScriptRoot
$LogDir = Join-Path $Root 'logs'
$LogFile = Join-Path $LogDir 'health-monitor.log'
$StateFile = Join-Path $LogDir 'health-monitor-state.json'
$Lock = Join-Path $LogDir '.health-monitor.lock'
$Perf = Join-Path $Root 'ai-perf.ps1'
$Starter = Join-Path $Root 'Start-LocalAI.bat'
. (Join-Path $Root 'ai-common.ps1')   # shared Invoke-AiProcess (was inlined below)
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Load-State {
  if (Test-Path $StateFile) {
    try { return Get-Content $StateFile -Raw | ConvertFrom-Json -AsHashtable } catch { }
  }
  return @{ lastStatus = 'unknown'; lastSignature = ''; lastNotify = '' }
}

function Save-State($s) {
  $s | ConvertTo-Json -Depth 6 | Set-Content -Path $StateFile -Encoding utf8
}

function Notify([string]$title, [string]$message) {
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
    $ni = [System.Windows.Forms.NotifyIcon]::new()
    $ni.Icon = [System.Drawing.SystemIcons]::Information
    $ni.Visible = $true
    $ni.ShowBalloonTip(8000, $title, $message, [System.Windows.Forms.ToolTipIcon]::Info)
    Start-Sleep -Seconds 9
    $ni.Dispose()
  } catch { }
}

# Invoke-AiProcess is provided by ai-common.ps1 (dot-sourced above).

function Join-CheckResult([string]$Name, [pscustomobject]$Result) {
  "==== $Name (exit $($Result.Code)) ====`n$($Result.Text)"
}

function Run-MonitorChecks {
  $parts = @()
  $code = 0

  $health = Invoke-AiProcess 'python' @('-m', 'localai', 'health') $HealthTimeoutSec $Root
  $parts += (Join-CheckResult 'localai health' $health)
  if ($health.Code -ne 0) { $code = $health.Code }

  if (Test-Path -LiteralPath $Perf) {
    $perf = Invoke-AiProcess 'pwsh' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Perf, '-Strict') 120 $Root
    $parts += (Join-CheckResult 'ai-perf.ps1 -Strict' $perf)
    if ($perf.Code -ne 0 -and $code -eq 0) { $code = $perf.Code }
  } else {
    $parts += '==== ai-perf.ps1 -Strict (exit 0) ===='
    $parts += '[monitor] ai-perf.ps1 missing; performance drift check skipped'
  }

  return [pscustomobject]@{ Code = $code; Text = ($parts -join "`n`n") }
}

function Append-Log([string]$text) {
  $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  Add-Content -Path $LogFile -Encoding utf8 -Value ("`n## $stamp`n$text")
  try {
    $lines = Get-Content $LogFile
    if ($lines.Count -gt 2000) {
      $lines | Select-Object -Last 1600 | Set-Content -Path $LogFile -Encoding utf8
    }
  } catch { }
}

function Release-HealthMonitorLock {
  if ($script:HealthMonitorLock) {
    try { $script:HealthMonitorLock.Close() } catch { }
    $script:HealthMonitorLock = $null
    try { Remove-Item $Lock -Force -ErrorAction SilentlyContinue } catch { }
  }
}

$script:HealthMonitorLock = $null
try {
  $script:HealthMonitorLock = [System.IO.File]::Open($Lock, 'OpenOrCreate', 'ReadWrite', 'None')
} catch {
  Write-Host '[monitor] another health monitor run is already in progress; exiting.'
  exit 2
}

$exitCode = 1
try {
$state = Load-State
$first = Run-MonitorChecks
$final = $first
$repaired = $false

if ($first.Code -ne 0 -and $Repair -and (Test-Path $Starter)) {
  Append-Log "[repair] initial health failed; running Start-LocalAI.bat /noopen`n$($first.Text)"
  $repair = Invoke-AiProcess 'cmd.exe' @('/d', '/c', $Starter, '/noopen') $RepairTimeoutSec $Root
  $repaired = $true
  if ($repair.Code -ne 0) {
    Append-Log "[repair] Start-LocalAI.bat /noopen failed or timed out (exit $($repair.Code))`n$($repair.Text)"
  }
  $final = Run-MonitorChecks
}

$status = if ($final.Code -eq 0) { 'OK' } else { 'FAIL' }
$failLines = @()
if ($final.Code -ne 0) {
  $failLines = ($final.Text -split "`n") | Where-Object { $_ -match '^\[FAIL\]' }
}
$signature = ($failLines -join ' | ')
if (-not $signature -and $final.Code -ne 0) {
  $signature = @(($final.Text -split "`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
  if (-not $signature) { $signature = 'health failed' }
}

$summary = if ($repaired) {
  "[monitor] status=$status after repair attempt`n$($final.Text)"
} else {
  "[monitor] status=$status`n$($final.Text)"
}
Append-Log $summary

$shouldNotify = $false
$message = ''
if ($final.Code -ne 0) {
  $lastNotify = $null
  try { if ($state.lastNotify) { $lastNotify = [datetime]$state.lastNotify } } catch { }
  $hoursSince = if ($lastNotify) { ((Get-Date) - $lastNotify).TotalHours } else { 999 }
  if ($state.lastStatus -ne 'FAIL' -or $state.lastSignature -ne $signature -or $hoursSince -ge 6) {
    $shouldNotify = $true
    $message = if ($signature) { $signature } else { 'localai health check failed' }
  }
} elseif ($repaired) {
  $shouldNotify = $true
  $message = 'localai was unhealthy but Start-LocalAI repaired it.'
} elseif ($NotifyOnSuccess -and $state.lastStatus -ne 'OK') {
  $shouldNotify = $true
  $message = 'localai health is OK.'
}

$state.lastStatus = $status
$state.lastSignature = $signature
if ($shouldNotify) {
  $state.lastNotify = (Get-Date).ToString('o')
  Notify 'localai health monitor' $message
}
Save-State $state

$exitCode = $final.Code
} finally {
  Release-HealthMonitorLock
}
exit $exitCode
