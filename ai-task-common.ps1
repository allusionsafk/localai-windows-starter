#requires -Version 7.0
<#
  ai-task-common.ps1 - shared helpers for every AI-* scheduled task installer
  and for Repair-AITasks.ps1. Dot-source it:

      . (Join-Path $PSScriptRoot 'ai-task-common.ps1')

  Single source of truth for HOW an AI-* task is launched, so the
  "blank window" / "version-pinned pwsh" bug can only ever be fixed (or
  reintroduced) in one place instead of four. Per-task logic - arguments,
  timeouts, triggers, summary output - stays in each installer.
#>

function Get-AIStablePwsh {
  # The version-independent WindowsApps execution alias, so a PowerShell
  # update never orphans a task by deleting a version-pinned exe path.
  # Falls back to whatever pwsh is on PATH, then the bare name.
  $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
  if (Test-Path $alias) { return $alias }
  $cmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return 'pwsh.exe'
}

function New-AITaskAction {
  # Build the scheduled-task Action that launches pwsh with NO console window,
  # ever. conhost.exe --headless runs the console host headless and does not
  # hand off to Windows Terminal (which is what popped the blank window).
  #   -PwshArguments : everything that would follow the pwsh exe, e.g.
  #                    '-NoProfile -ExecutionPolicy Bypass -File "..." -Mode Auto'
  #   -WorkingDirectory : optional CWD for the task.
  param(
    [Parameter(Mandatory)][string]$PwshArguments,
    [string]$WorkingDirectory
  )
  $pwsh = Get-AIStablePwsh
  $a = $PwshArguments.Trim()
  if ($a -notmatch '(?i)(^|\s)-WindowStyle\s+Hidden(\s|$)') {
    $a = '-WindowStyle Hidden ' + $a
  }
  $conhost  = Join-Path $env:WINDIR 'System32\conhost.exe'
  $argument = '--headless "' + $pwsh + '" ' + $a
  if ($WorkingDirectory) {
    New-ScheduledTaskAction -Execute $conhost -Argument $argument -WorkingDirectory $WorkingDirectory
  } else {
    New-ScheduledTaskAction -Execute $conhost -Argument $argument
  }
}

function New-AITaskSettings {
  # Laptop-friendly settings shared by every AI-* task: catch up if the PC was
  # off, allow on battery, don't double-run, require a network, and let the
  # script own its per-step timeouts under this outer cap.
  param([Parameter(Mandatory)][int]$TimeLimitSec)
  New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -RunOnlyIfNetworkAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Seconds $TimeLimitSec)
}

function Get-AITaskPrincipal {
  # Interactive logon = runs in the user's desktop session (so Docker is up and
  # notifications can show). Limited run level = no admin prompt.
  $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
  New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
}

function Register-AITask {
  # Register (or replace) a task with a uniform, legible success/failure report.
  # Returns $true on success, $false on failure (so callers can `exit 1`).
  param(
    [Parameter(Mandatory)][string]$TaskName,
    [Parameter(Mandatory)]$Action,
    [Parameter(Mandatory)]$Trigger,
    [Parameter(Mandatory)]$Settings,
    [Parameter(Mandatory)]$Principal,
    [string]$Description
  )
  try {
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger `
      -Settings $Settings -Principal $Principal -Force -Description $Description -ErrorAction Stop | Out-Null
    return $true
  } catch {
    Write-Host "[!] Could not register '$TaskName': $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "    If this says Access Denied, run this once from an elevated pwsh." -ForegroundColor Yellow
    return $false
  }
}
