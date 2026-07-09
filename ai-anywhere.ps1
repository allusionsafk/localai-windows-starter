#requires -Version 7.0
<#
  ai-anywhere.ps1 - Secure device access for localai.

  Uses Tailscale Serve to publish the local Open WebUI port only to devices in
  your tailnet. This is the safe path for phones, tablets, and other laptops on
  any network, including public WiFi, without opening LocalAI to the local LAN
  or the public internet.

  Examples:
    pwsh -File ai-anywhere.ps1
    pwsh -File ai-anywhere.ps1 -InstallTailscale
    pwsh -File ai-anywhere.ps1 -Apply
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [switch]$Apply,
  [switch]$InstallTailscale,
  [switch]$Open,
  [ValidateRange(1, 65535)]
  [int]$Port = 3000
)

$ErrorActionPreference = 'Stop'

$Root = $PSScriptRoot
$Compose = Join-Path $Root 'docker-compose.yml'
$DownloadUrl = 'https://tailscale.com/download/windows'
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

function Resolve-Tailscale {
  $cmd = Get-Command 'tailscale.exe' -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }

  $candidates = @(
    (Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Tailscale\tailscale.exe'),
    (Join-Path $env:LOCALAPPDATA 'Tailscale\tailscale.exe')
  ) | Where-Object { $_ }

  foreach ($candidate in $candidates) {
    if (Test-Path $candidate) { return $candidate }
  }
  return $null
}

function Invoke-ProcessCaptured([string]$FilePath, [string[]]$ArgumentList = @(), [int]$TimeoutSec = 30) {
  $p = $null
  try {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    foreach ($arg in @($ArgumentList)) { [void]$psi.ArgumentList.Add([string]$arg) }

    $p = [System.Diagnostics.Process]::new()
    $p.StartInfo = $psi
    [void]$p.Start()
    $stdoutTask = $p.StandardOutput.ReadToEndAsync()
    $stderrTask = $p.StandardError.ReadToEndAsync()

    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
      try { $p.Kill($true) } catch { try { $p.Kill() } catch { } }
      return [pscustomobject]@{ Code = 124; Text = "Timed out after ${TimeoutSec}s: $FilePath $($ArgumentList -join ' ')" }
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

function HttpCode([string]$Url, [int]$Timeout = 5) {
  try {
    $r = Invoke-WebRequest -Uri $Url -TimeoutSec $Timeout -UseBasicParsing
    return [int]$r.StatusCode
  } catch {
    return 0
  }
}

function Install-TailscaleWithWinget {
  $winget = Get-Command 'winget.exe' -ErrorAction SilentlyContinue
  if (-not $winget) {
    Line 'FAIL' 'Tailscale install' "winget not found; install from $DownloadUrl"
    return
  }

  $cmdArgs = @(
    'install',
    '--id', 'Tailscale.Tailscale',
    '-e',
    '--source', 'winget',
    '--accept-package-agreements',
    '--accept-source-agreements'
  )

  if ($PSCmdlet.ShouldProcess('Tailscale.Tailscale', 'install with winget')) {
    Line 'OK' 'Tailscale install' 'starting winget install'
    $result = Invoke-ProcessCaptured $winget.Source $cmdArgs 900
    if ($result.Code -eq 0) {
      Line 'OK' 'Tailscale install' 'installed or already present'
    } else {
      $text = ($result.Text -replace '\s+', ' ').Trim()
      Line 'FAIL' 'Tailscale install' $text
    }
  }
}

function Get-TailscaleSelf([string]$Tailscale) {
  $status = Invoke-ProcessCaptured $Tailscale @('status', '--json') 20
  if ($status.Code -ne 0 -or -not $status.Text) {
    return [pscustomobject]@{
      Connected = $false
      Detail = ($status.Text -replace '\s+', ' ').Trim()
      Url = ''
      DnsName = ''
      IPs = @()
    }
  }

  try {
    $json = $status.Text | ConvertFrom-Json
    $self = $json.Self
    $ips = @($self.TailscaleIPs | Where-Object { $_ })
    $dns = ([string]$self.DNSName).TrimEnd('.')
    $online = [bool]$self.Online
    $backend = [string]$json.BackendState
    $connected = $online -or $backend -eq 'Running'
    $url = if ($dns) { "https://$dns" } elseif ($ips.Count -gt 0) { "http://$($ips[0]):$Port" } else { '' }
    $notConnectedDetail = switch ($backend) {
      'NoState'    { 'Tailscale is not signed in - open Tailscale and sign in, then rerun this check' }
      'NeedsLogin' { 'Tailscale needs you to sign in - open Tailscale and sign in, then rerun this check' }
      'Starting'   { 'Tailscale is still starting up - wait a few seconds and rerun this check' }
      'Stopped'    { 'Tailscale is stopped - open Tailscale, then rerun this check' }
      default      { "Tailscale backend state: $backend" }
    }
    return [pscustomobject]@{
      Connected = $connected
      Detail = if ($connected) { "online as $($self.HostName)" } else { $notConnectedDetail }
      Url = $url
      DnsName = $dns
      IPs = $ips
    }
  } catch {
    return [pscustomobject]@{
      Connected = $false
      Detail = $_.Exception.Message
      Url = ''
      DnsName = ''
      IPs = @()
    }
  }
}

function Get-ServeStatus([string]$Tailscale) {
  $status = Invoke-ProcessCaptured $Tailscale @('serve', 'status') 20
  $text = ($status.Text -replace '\s+', ' ').Trim()
  return [pscustomobject]@{ Code = $status.Code; Text = $text }
}

Write-Host "==== localai secure anywhere access ====  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

if ($InstallTailscale) {
  Install-TailscaleWithWinget
}

$composeText = ''
if (Test-Path $Compose) { $composeText = Get-Content $Compose -Raw }
if ($composeText -match '127\.0\.0\.1:3000:8080') {
  Line 'OK' 'Open WebUI bind' 'localhost-only Docker publish'
} elseif ($composeText -match '0\.0\.0\.0:3000:8080') {
  Line 'WARN' 'Open WebUI bind' 'LAN-wide Docker publish; change to 127.0.0.1 for strict secure access'
} else {
  Line 'WARN' 'Open WebUI bind' 'could not confirm Docker port binding'
}

$owui = HttpCode "http://127.0.0.1:$Port/health" 3
if ($owui -eq 200) {
  Line 'OK' 'Open WebUI local' "http://127.0.0.1:$Port health HTTP 200"
} else {
  Line 'WARN' 'Open WebUI local' "health HTTP $owui; start Local AI before testing remote devices"
}

$tailscale = Resolve-Tailscale
if (-not $tailscale) {
  Line 'WARN' 'Tailscale' "not installed; run with -InstallTailscale or install from $DownloadUrl"
  Write-Host ("`nSummary: {0} OK, {1} WARN, {2} FAIL" -f $Ok, $Warn, $Fail)
  if ($Fail -gt 0) { exit 1 }
  exit 0
}

Line 'OK' 'Tailscale' $tailscale
$self = Get-TailscaleSelf $tailscale
if ($self.Connected) {
  $ipText = if ($self.IPs.Count -gt 0) { $self.IPs -join ', ' } else { 'no tailnet IP reported' }
  Line 'OK' 'Tailnet login' "$($self.Detail); $ipText"
} else {
  $detail = if ($self.Detail) { $self.Detail } else { 'open Tailscale and sign in' }
  Line 'WARN' 'Tailnet login' $detail
}

if ($Apply) {
  if (-not $self.Connected) {
    Line 'WARN' 'Tailscale Serve' 'sign in to Tailscale first, then rerun: pwsh -File ai-anywhere.ps1 -Apply'
  } elseif ($PSCmdlet.ShouldProcess("http://127.0.0.1:$Port", 'publish to your tailnet with Tailscale Serve')) {
    & $tailscale serve --bg $Port
    $serveExit = $LASTEXITCODE
    if ($serveExit -eq 0) {
      Line 'OK' 'Tailscale Serve' "proxying tailnet HTTPS to http://127.0.0.1:$Port"
    } else {
      Line 'WARN' 'Tailscale Serve' 'serve command failed or requires consent; see output above'
      Line 'WARN' 'Serve consent' 'follow any Tailscale consent URL printed above, then rerun -Apply'
    }
  }
}

$serveStatus = Get-ServeStatus $tailscale
if ($serveStatus.Code -eq 0 -and $serveStatus.Text -match "127\.0\.0\.1:$Port|localhost:$Port|:$Port") {
  $url = if ($self.Url) { $self.Url } else { 'the HTTPS URL shown by tailscale serve status' }
  Line 'OK' 'Anywhere URL' $url
} else {
  $hint = if ($Apply) { 'Serve is not active yet; see message above' } else { 'run: pwsh -File ai-anywhere.ps1 -Apply' }
  Line 'WARN' 'Anywhere URL' $hint
}

$funnel = Invoke-ProcessCaptured $tailscale @('funnel', 'status') 15
$funnelText = ($funnel.Text -replace '\s+', ' ').Trim()
if ($funnel.Code -eq 0 -and $funnelText -match 'https?://' -and $funnelText -notmatch 'not enabled|tailnet only') {
  Line 'WARN' 'Tailscale Funnel' 'public internet sharing appears enabled; use Serve, not Funnel, for localai'
} else {
  Line 'OK' 'Tailscale Funnel' 'not publishing localai to the public internet'
}

if ($Open -and $self.Url) {
  Start-Process $self.Url
}

Write-Host ("`nSummary: {0} OK, {1} WARN, {2} FAIL" -f $Ok, $Warn, $Fail)
if ($Fail -gt 0) { exit 1 }
exit 0
