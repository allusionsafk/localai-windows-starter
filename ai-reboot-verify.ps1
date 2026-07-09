#requires -Version 7.0
<#
  ai-reboot-verify.ps1 - one-shot post-reboot proof for the localai stack.

  -Run starts Local AI with Start-LocalAI.bat /noopen, then verifies the
  dashboard, Tailscale Serve, firewall posture, and full health summary.
  -InstallOnce registers the same run as an at-logon scheduled task for the
  next reboot/sign-in, then removes that task after it runs.
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
  [Parameter(ParameterSetName = 'Run')]
  [switch]$Run,

  [Parameter(ParameterSetName = 'Install')]
  [switch]$InstallOnce,

  [Parameter(ParameterSetName = 'Uninstall')]
  [switch]$Uninstall,

  [Parameter(ParameterSetName = 'Run')]
  [switch]$UninstallAfterRun,

  [Parameter(ParameterSetName = 'Install')]
  [ValidateRange(1, 30)]
  [int]$DelayMinutes = 3,

  [ValidateRange(60, 1800)]
  [int]$StartTimeoutSec = 900,

  [ValidateRange(30, 900)]
  [int]$CheckTimeoutSec = 300
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$TaskName = 'AI-RebootVerifyOnce'
$LogDir = Join-Path $Root 'logs'
$LogFile = Join-Path $LogDir 'reboot-verification.log'
$ScriptPath = $PSCommandPath
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Resolve-Pwsh {
  $cmd = Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }

  $cmd = Get-Command 'powershell.exe' -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }

  throw 'PowerShell was not found.'
}

function Invoke-ProcessCaptured([string]$FilePath, [string[]]$ArgumentList = @(), [int]$TimeoutSec = 300) {
  $p = $null
  try {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $Root
    foreach ($arg in @($ArgumentList)) { [void]$psi.ArgumentList.Add([string]$arg) }

    $p = [System.Diagnostics.Process]::new()
    $p.StartInfo = $psi
    [void]$p.Start()
    $stdoutTask = $p.StandardOutput.ReadToEndAsync()
    $stderrTask = $p.StandardError.ReadToEndAsync()

    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
      try { $p.Kill($true) } catch { try { $p.Kill() } catch { } }
      return [pscustomobject]@{
        Code = 124
        Text = "Timed out after ${TimeoutSec}s: $FilePath $($ArgumentList -join ' ')"
      }
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

function Invoke-ProcessWait([string]$FilePath, [string[]]$ArgumentList = @(), [int]$TimeoutSec = 300) {
  $p = $null
  try {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError = $false
    $psi.CreateNoWindow = $false
    $psi.WorkingDirectory = $Root
    foreach ($arg in @($ArgumentList)) { [void]$psi.ArgumentList.Add([string]$arg) }

    $p = [System.Diagnostics.Process]::new()
    $p.StartInfo = $psi
    [void]$p.Start()

    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
      try { $p.Kill($true) } catch { try { $p.Kill() } catch { } }
      return [pscustomobject]@{
        Code = 124
        Text = "Timed out after ${TimeoutSec}s: $FilePath $($ArgumentList -join ' ')"
      }
    }

    return [pscustomobject]@{ Code = $p.ExitCode; Text = '' }
  } catch {
    return [pscustomobject]@{ Code = 1; Text = $_.Exception.Message }
  } finally {
    if ($p) { $p.Dispose() }
  }
}

function Append-Log([string]$Text) {
  Add-Content -LiteralPath $LogFile -Encoding utf8 -Value $Text
}

function Test-Patterns([string]$Text, [string[]]$RequiredPatterns, [string[]]$RejectPatterns) {
  $problems = @()
  foreach ($pattern in @($RequiredPatterns)) {
    if ($pattern -and $Text -notmatch $pattern) {
      $problems += "missing required pattern: $pattern"
    }
  }
  foreach ($pattern in @($RejectPatterns)) {
    if ($pattern -and $Text -match $pattern) {
      $problems += "matched rejected pattern: $pattern"
    }
  }
  return $problems
}

function Invoke-StepNoCapture(
  [string]$Name,
  [string]$FilePath,
  [string[]]$ArgumentList,
  [int]$TimeoutSec
) {
  Write-Host "== $Name =="
  Append-Log "`n## $Name"
  Append-Log "Command: $FilePath $($ArgumentList -join ' ')"
  Append-Log 'Output: shown live in the scheduled-task console'

  $result = Invoke-ProcessWait $FilePath $ArgumentList $TimeoutSec
  Append-Log "Exit: $($result.Code)"
  if ($result.Text) { Append-Log $result.Text }

  if ($result.Code -eq 0) {
    Write-Host "[OK] $Name"
    Append-Log "Result: OK"
    return $true
  }

  Write-Host "[FAIL] $Name - exit code $($result.Code)"
  Append-Log "Result: FAIL - exit code $($result.Code)"
  return $false
}

function Invoke-Step(
  [string]$Name,
  [string]$FilePath,
  [string[]]$ArgumentList,
  [int]$TimeoutSec,
  [string[]]$RequiredPatterns = @(),
  [string[]]$RejectPatterns = @()
) {
  Write-Host "== $Name =="
  Append-Log "`n## $Name"
  Append-Log "Command: $FilePath $($ArgumentList -join ' ')"

  $result = Invoke-ProcessCaptured $FilePath $ArgumentList $TimeoutSec
  Append-Log "Exit: $($result.Code)"
  if ($result.Text) { Append-Log $result.Text }

  $problems = @()
  if ($result.Code -ne 0) { $problems += "exit code $($result.Code)" }
  $problems += @(Test-Patterns $result.Text $RequiredPatterns $RejectPatterns)

  if ($problems.Count -eq 0) {
    Write-Host "[OK] $Name"
    Append-Log "Result: OK"
    return $true
  }

  Write-Host "[FAIL] $Name - $($problems -join '; ')"
  Append-Log "Result: FAIL - $($problems -join '; ')"
  return $false
}

function Get-BootDetail {
  try {
    $os = Get-CimInstance Win32_OperatingSystem
    return $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss')
  } catch {
    return 'unknown'
  }
}

function Install-OneShotTask {
  $pwsh = Resolve-Pwsh
  $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
  $cmdArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Run -UninstallAfterRun -StartTimeoutSec {1} -CheckTimeoutSec {2}' -f $ScriptPath, $StartTimeoutSec, $CheckTimeoutSec
  $action = New-ScheduledTaskAction -Execute $pwsh -Argument $cmdArgs -WorkingDirectory $Root
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $me
  $trigger.Delay = "PT${DelayMinutes}M"
  $settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Seconds ([Math]::Max(1800, $StartTimeoutSec + ($CheckTimeoutSec * 3))))
  $principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited

  Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Force `
    -Description "One-shot localai post-reboot verification; writes $LogFile and removes itself after running." |
    Out-Null

  Write-Host "[OK] Scheduled one-shot verifier '$TaskName' at logon after ${DelayMinutes}m."
  Write-Host "     Log: $LogFile"
}

function Uninstall-OneShotTask {
  $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if ($task) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "[OK] Removed scheduled task '$TaskName'."
  } else {
    Write-Host "[OK] Scheduled task '$TaskName' is not registered."
  }
}

function Invoke-RebootVerification {
  $pwsh = Resolve-Pwsh
  $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $boot = Get-BootDetail

  Append-Log "`n# Reboot verification run: $stamp"
  Append-Log "Boot time: $boot"
  Append-Log "User: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
  Write-Host "==== localai reboot verification ====  $stamp"
  Write-Host "Boot time: $boot"
  Write-Host "Log: $LogFile"

  $checks = @()
  $checks += Invoke-Step 'Dashboard self-test' $pwsh @('-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'AI-Dashboard.ps1'), '-SelfTest') 90 @('Summary:\s+16 OK,\s+0 WARN,\s+0 FAIL')
  $checks += Invoke-StepNoCapture 'Startup wrapper' 'cmd.exe' @('/d', '/c', (Join-Path $Root 'Start-LocalAI.bat'), '/noopen') $StartTimeoutSec
  $checks += Invoke-Step 'Tailscale Serve' $pwsh @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'ai-anywhere.ps1')) $CheckTimeoutSec @('Summary:\s+6 OK,\s+0 WARN,\s+0 FAIL')
  $checks += Invoke-Step 'Firewall audit' $pwsh @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'ai-firewall.ps1')) $CheckTimeoutSec @('Summary:\s+2 OK,\s+0 WARN,\s+0 FAIL')
  $checks += Invoke-Step 'Full health' 'python' @('-m', 'localai', 'health') $CheckTimeoutSec @('Summary:\s+\d+ OK,\s+0 WARN,\s+0 FAIL')

  $failed = @($checks | Where-Object { -not $_ }).Count
  if ($failed -eq 0) {
    Append-Log "`nFinal result: OK"
    Write-Host "`nFinal result: OK"
    return 0
  }

  Append-Log "`nFinal result: FAIL ($failed failed step(s))"
  Write-Host "`nFinal result: FAIL ($failed failed step(s))"
  return 1
}

if ($InstallOnce) {
  Install-OneShotTask
  exit 0
}

if ($Uninstall) {
  Uninstall-OneShotTask
  exit 0
}

$exitCode = Invoke-RebootVerification
if ($UninstallAfterRun) {
  try { Uninstall-OneShotTask } catch { Write-Host "[WARN] Could not remove ${TaskName}: $($_.Exception.Message)" }
}
exit $exitCode
