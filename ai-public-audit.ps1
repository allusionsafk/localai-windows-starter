#requires -Version 7.0
<#
  ai-public-audit.ps1 - Lightweight public-repo readiness audit.

  This private repo intentionally contains laptop-specific defaults. Use this
  script before extracting a separate public template repo so private hostnames,
  user paths, and hardware assumptions do not get copied by accident.
#>
[CmdletBinding()]
param(
  [switch]$Strict,
  [int]$Context = 0,
  [string[]]$ExtraPattern = @()
)

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

function Line([string]$Level, [string]$Name, [string]$Detail) {
  $color = switch ($Level) {
    'OK' { 'Green' }
    'WARN' { 'Yellow' }
    'FAIL' { 'Red' }
    default { 'Gray' }
  }
  Write-Host ("[{0}] {1,-22} {2}" -f $Level, $Name, $Detail) -ForegroundColor $color
}

function Escape-RegexLiteral([string]$Text) {
  [regex]::Escape($Text)
}

function Get-GitHubOwnerFromOrigin {
  try {
    $url = (git remote get-url origin 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $url) { return $null }
    if ($url -match 'github\.com[:/](?<owner>[^/]+)/(?<repo>[^/.]+)') {
      return $Matches.owner
    }
  } catch {}
  return $null
}

function Get-RelativePath([string]$Path) {
  try {
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    return [IO.Path]::GetRelativePath($Root, $resolved)
  } catch {
    return $Path
  }
}

$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) {
  Line 'FAIL' 'git' 'git.exe is required for tracked-file audit'
  exit 2
}

$tracked = @(git ls-files)
if ($LASTEXITCODE -ne 0 -or $tracked.Count -eq 0) {
  Line 'FAIL' 'tracked files' 'git ls-files returned no files'
  exit 2
}

$hardwarePattern = ('RTX\s*' + '4080') + '|' + ('laptop ' + 'GPU')

$patterns = @(
  @{ Name = 'Windows user path'; Pattern = 'C:\\Users\\' + (Escape-RegexLiteral $env:USERNAME) + '|Users/' + (Escape-RegexLiteral $env:USERNAME) },
  @{ Name = 'Computer name'; Pattern = '\b' + (Escape-RegexLiteral $env:COMPUTERNAME) + '\b' },
  @{ Name = 'Tailnet URL'; Pattern = '\b[a-z0-9-]+\.tail[0-9a-f]+\.ts\.net\b' },
  @{ Name = 'Tailscale IPv4'; Pattern = '\b100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}\b' },
  @{ Name = 'Tailscale IPv6'; Pattern = '\bfd[0-9a-f]{2}:[0-9a-f]{1,4}:[0-9a-f]{1,4}\b' },
  @{ Name = 'Laptop hardware'; Pattern = $hardwarePattern }
)

$originOwner = Get-GitHubOwnerFromOrigin
if ($originOwner) {
  $patterns += @{ Name = 'Origin GitHub owner'; Pattern = '\b' + (Escape-RegexLiteral $originOwner) + '\b' }
}

foreach ($p in $ExtraPattern) {
  if ($p) { $patterns += @{ Name = 'Extra pattern'; Pattern = $p } }
}

$findings = New-Object System.Collections.Generic.List[object]

foreach ($entry in $patterns) {
  $hits = @(Select-String -LiteralPath $tracked -Pattern $entry.Pattern -ErrorAction SilentlyContinue -Context $Context)
  foreach ($hit in $hits) {
    $findings.Add([pscustomobject]@{
      Kind = $entry.Name
      File = Get-RelativePath $hit.Path
      Line = $hit.LineNumber
      Text = ($hit.Line.Trim() -replace '\s+', ' ')
    })
  }
}

Write-Host "==== localai public-readiness audit ====  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Line 'OK' 'tracked files' "$($tracked.Count) files scanned"

if ($findings.Count -eq 0) {
  Line 'OK' 'private markers' 'no built-in marker patterns found'
  exit 0
}

$grouped = $findings | Group-Object Kind | Sort-Object Name
foreach ($group in $grouped) {
  Line 'WARN' $group.Name "$($group.Count) hit(s)"
}

Write-Host ''
foreach ($finding in ($findings | Sort-Object Kind, File, Line)) {
  Write-Host ("{0}:{1}: [{2}] {3}" -f $finding.File, $finding.Line, $finding.Kind, $finding.Text)
}

Write-Host ''
if ($Strict) {
  Line 'FAIL' 'public readiness' 'private/laptop-specific markers found'
  exit 1
}

Line 'WARN' 'public readiness' 'markers found; expected in this private repo, blocking for a public template only with -Strict'
exit 0
