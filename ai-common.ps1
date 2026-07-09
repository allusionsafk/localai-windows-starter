<#
  ai-common.ps1 - shared helpers for the localai scripts.

  Dot-source it from a script that lives in this folder:
      . (Join-Path $PSScriptRoot 'ai-common.ps1')

  Behaviour-preserving home for logic that was copy-pasted across many
  scripts. Add a helper here only when at least one script uses it.
#>

function Resolve-AiCommandPath {
  # Full path of a command if resolvable, else the name unchanged.
  param([Parameter(Mandatory)][string]$Name)
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $Name
}

function Invoke-AiProcess {
  # Run a process, capture stdout+stderr, enforce a timeout. Never throws.
  # Returns [pscustomobject]@{ Code; Text }. Code 124 = timed out, 1 = launch error.
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [string[]]$ArgumentList = @(),
    [int]$TimeoutSec = 30,
    [string]$WorkingDirectory
  )
  $p = $null
  try {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Resolve-AiCommandPath $FilePath)
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
      return [pscustomobject]@{ Code = 124; Text = "Timed out after ${TimeoutSec}s" }
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
