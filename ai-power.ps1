#requires -Version 7.0
<#
  ai-power.ps1 - Read-only battery/power guard for the localai stack.

  Use this when the laptop is unplugged. It checks whether LocalAI, Ollama,
  Docker, GPU memory, and the warm task are likely costing battery, then points
  at the existing stop/game-mode scripts. It does not stop anything by itself.
#>
[CmdletBinding()]
param(
  [switch]$Strict,
  [ValidateRange(5, 120)]
  [int]$TimeoutSec = 8
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
  Write-Host ("[{0}] {1,-22} {2}" -f $Status, $Name, $Detail) -ForegroundColor $color
}

. (Join-Path $Root 'ai-common.ps1')   # shared Invoke-AiProcess (was inlined below)
function Invoke-ProcessCaptured([string]$FilePath, [string[]]$ArgumentList = @(), [int]$Seconds = 8) {
  return Invoke-AiProcess $FilePath $ArgumentList $Seconds $Root
}

function Get-PowerState {
  function Get-SystemPowerStatus {
    try {
      if (-not ('LocalAI.Power.Native' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace LocalAI.Power {
  public static class Native {
    [StructLayout(LayoutKind.Sequential)]
    public struct SYSTEM_POWER_STATUS {
      public byte ACLineStatus;
      public byte BatteryFlag;
      public byte BatteryLifePercent;
      public byte SystemStatusFlag;
      public int BatteryLifeTime;
      public int BatteryFullLifeTime;
    }

    [DllImport("kernel32.dll")]
    public static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS status);
  }
}
'@
      }

      $status = [LocalAI.Power.Native+SYSTEM_POWER_STATUS]::new()
      if ([LocalAI.Power.Native]::GetSystemPowerStatus([ref]$status)) {
        return $status
      }
    } catch {}
    return $null
  }

  $batteries = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
  if ($batteries.Count -eq 0) {
    $native = Get-SystemPowerStatus
    if ($native) {
      $noBattery = ($native.BatteryFlag -band 128) -ne 0
      $charge = if ($native.BatteryLifePercent -ne 255) { [int]$native.BatteryLifePercent } else { $null }
      $onBattery = $native.ACLineStatus -eq 0
      if (-not $noBattery) {
        $state = if ($onBattery) { 'discharging' } elseif ($native.ACLineStatus -eq 1) { 'plugged in or full' } else { 'power state unknown' }
        $detail = if ($null -ne $charge) { "$state, $charge% remaining" } else { $state }
        return [pscustomobject]@{
          HasBattery = $true
          OnBattery = $onBattery
          Charge = $charge
          Detail = $detail
        }
      }
    }

    return [pscustomobject]@{
      HasBattery = $false
      OnBattery = $false
      Charge = $null
      Detail = 'no battery detected'
    }
  }

  $chargeValues = @($batteries | ForEach-Object { $_.EstimatedChargeRemaining } | Where-Object { $null -ne $_ })
  $charge = if ($chargeValues.Count -gt 0) { [math]::Round((($chargeValues | Measure-Object -Average).Average), 0) } else { $null }
  $onBattery = @($batteries | Where-Object { $_.BatteryStatus -eq 1 }).Count -gt 0
  $state = if ($onBattery) { 'discharging' } else { 'plugged in or full' }
  $detail = if ($null -ne $charge) { "$state, $charge% remaining" } else { $state }
  [pscustomobject]@{
    HasBattery = $true
    OnBattery = $onBattery
    Charge = $charge
    Detail = $detail
  }
}

function Get-LoadedOllamaModels {
  try {
    $ps = Invoke-RestMethod 'http://localhost:11434/api/ps' -TimeoutSec 3
    return @($ps.models | ForEach-Object {
      if ($_.name) { $_.name } elseif ($_.model) { $_.model }
    } | Where-Object { $_ })
  } catch {
    return @()
  }
}

function Get-LocalAIContainerState {
  $docker = Invoke-ProcessCaptured 'docker' @('ps', '--format', '{{.Names}}\t{{.Status}}') $TimeoutSec
  if ($docker.Code -ne 0) {
    return [pscustomobject]@{ Code = $docker.Code; Rows = @(); Detail = $docker.Text }
  }

  $rows = @()
  if ($docker.Text) {
    $rows = @($docker.Text -split "`r?`n" | Where-Object { $_ -match '^localai-' })
  }
  [pscustomobject]@{ Code = 0; Rows = $rows; Detail = '' }
}

function Get-AIWarmState {
  try {
    $task = Get-ScheduledTask -TaskName 'AI-Warm' -ErrorAction SilentlyContinue
    if (-not $task) { return 'not installed' }
    return [string]$task.State
  } catch {
    return 'unknown'
  }
}

Write-Host "==== localai power guard ====  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

$power = Get-PowerState
if (-not $power.HasBattery) {
  Line 'OK' 'Power source' $power.Detail
} elseif ($power.OnBattery) {
  if ($null -ne $power.Charge -and $power.Charge -le 20) {
    Line 'WARN' 'Power source' "$($power.Detail); consider stopping LocalAI"
  } else {
    Line 'WARN' 'Power source' $power.Detail
  }
} else {
  Line 'OK' 'Power source' $power.Detail
}

$models = @(Get-LoadedOllamaModels)
if ($models.Count -eq 0) {
  Line 'OK' 'Ollama models' 'none loaded'
} elseif ($power.OnBattery) {
  Line 'WARN' 'Ollama models' ('loaded on battery: ' + ($models -join ', '))
} else {
  Line 'OK' 'Ollama models' ('loaded: ' + ($models -join ', '))
}

$containerState = Get-LocalAIContainerState
$containers = @($containerState.Rows)
if ($containerState.Code -ne 0) {
  $detail = if ($containerState.Detail) { $containerState.Detail } else { "docker ps exit $($containerState.Code)" }
  Line 'WARN' 'Docker containers' "check unavailable: $detail"
} elseif ($containers.Count -eq 0) {
  Line 'OK' 'Docker containers' 'no localai containers running'
} elseif ($power.OnBattery) {
  Line 'WARN' 'Docker containers' "$($containers.Count) localai container(s) running on battery"
} else {
  Line 'OK' 'Docker containers' "$($containers.Count) localai container(s) running"
}

$smi = Invoke-ProcessCaptured 'nvidia-smi' @('--query-gpu=memory.used,memory.total,utilization.gpu', '--format=csv,noheader,nounits') $TimeoutSec
if ($smi.Code -eq 0 -and $smi.Text) {
  $first = ($smi.Text -split "`r?`n")[0]
  $parts = $first -split ','
  $usedMb = [double]($parts[0].Trim())
  $totalMb = [double]($parts[1].Trim())
  $util = [double]($parts[2].Trim())
  $usedGb = [math]::Round($usedMb / 1024, 1)
  $totalGb = [math]::Round($totalMb / 1024, 1)
  if ($power.OnBattery -and ($usedMb -ge 4096 -or $util -ge 10)) {
    Line 'WARN' 'GPU load' "$usedGb/$totalGb GB used, $util% utilization"
  } else {
    Line 'OK' 'GPU load' "$usedGb/$totalGb GB used, $util% utilization"
  }
} else {
  Line 'OK' 'GPU load' 'nvidia-smi unavailable or no NVIDIA GPU reported'
}

$warmState = Get-AIWarmState
if ($power.OnBattery -and $warmState -eq 'Ready') {
  Line 'WARN' 'AI-Warm task' 'enabled; Game Mode can disable it before travel/gaming'
} else {
  Line 'OK' 'AI-Warm task' $warmState
}

Write-Host ("`nSummary: {0} OK, {1} WARN, {2} FAIL" -f $Ok, $Warn, $Fail)

if ($power.OnBattery -and $Warn -gt 0) {
  Write-Host ''
  Write-Host 'Battery saver options:'
  Write-Host '  localai stop'
  Write-Host '  localai game-mode --disable-warm-task'
}

if ($Fail -gt 0) { exit 1 }
if ($Strict -and $Warn -gt 0) { exit 1 }
exit 0
