#requires -Version 7.0
<#
  tests/Invoke-Checks.ps1 - the repo's verification gate (local + CI).

  Runs the cheap, behaviour-safe checks that should pass before any commit:
  PowerShell parse, node --check, JSON parse, docker compose config, the
  dashboard self-test, a static-analysis pass, and a regression test for the
  $args automatic-variable footgun that once broke every dashboard button.

  Exit code 0 = all gates passed; 1 = at least one failed. No side effects:
  nothing starts the stack, loads a model, or touches the network.

  Usage:  pwsh -File tests/Invoke-Checks.ps1 [-SkipAnalyzer]
#>
[CmdletBinding()]
param([switch]$SkipAnalyzer)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$script:Fail = 0
$results = [System.Collections.Generic.List[object]]::new()

function Add-Result([string]$Gate, [bool]$Ok, [string]$Detail = '') {
    $results.Add([pscustomobject]@{ Gate = $Gate; Status = $(if ($Ok) { 'PASS' } else { 'FAIL' }); Detail = $Detail })
    if (-not $Ok) { $script:Fail++ }
}

# Repo source files, excluding generated/data dirs so local runs match CI (which
# only checks out tracked files).
$excluded = '[\\/](\.git|logs|backups|node_modules)[\\/]'
$psFiles  = @(Get-ChildItem $Root -Recurse -Filter *.ps1  -File | Where-Object { $_.FullName -notmatch $excluded })
$mjsFiles = @(Get-ChildItem $Root -Recurse -Filter *.mjs  -File | Where-Object { $_.FullName -notmatch $excluded })
$jsonFiles = @(Get-ChildItem $Root -Recurse -Filter *.json -File | Where-Object { $_.FullName -notmatch $excluded })

# 1. PowerShell parses cleanly.
$parseBad = foreach ($f in $psFiles) {
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
    if ($errs) { "$($f.Name) ($($errs.Count))" }
}
Add-Result 'PowerShell parse' (-not $parseBad) ("$($psFiles.Count) files" + $(if ($parseBad) { "; bad: $($parseBad -join ', ')" }))

# 2. JavaScript modules syntax-check.
$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
    $mjsBad = foreach ($f in $mjsFiles) {
        & $node.Source --check $f.FullName 2>$null
        if ($LASTEXITCODE -ne 0) { $f.Name }
    }
    Add-Result 'node --check (.mjs)' (-not $mjsBad) ("$($mjsFiles.Count) files" + $(if ($mjsBad) { "; bad: $($mjsBad -join ', ')" }))
} else {
    Add-Result 'node --check (.mjs)' $true 'SKIPPED (node not found)'
}

# 3. JSON parses.
$jsonBad = foreach ($f in $jsonFiles) {
    try { Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json -ErrorAction Stop | Out-Null }
    catch { $f.Name }
}
Add-Result 'JSON parse' (-not $jsonBad) ("$($jsonFiles.Count) files" + $(if ($jsonBad) { "; bad: $($jsonBad -join ', ')" }))

# 4. docker compose config (syntax only; client-side, no daemon needed).
$compose = Join-Path $Root 'docker-compose.yml'
$docker = Get-Command docker -ErrorAction SilentlyContinue
if ($docker -and (Test-Path $compose)) {
    $out = & $docker.Source compose -f $compose config -q 2>&1
    $code = $LASTEXITCODE
    if ($code -eq 0) {
        Add-Result 'docker compose config' $true
    } elseif ("$out" -match 'daemon|pipe|connect|dial') {
        Add-Result 'docker compose config' $true 'SKIPPED (docker daemon unavailable)'
    } else {
        Add-Result 'docker compose config' $false ("$out" -replace '\s+', ' ').Trim()
    }
} else {
    Add-Result 'docker compose config' $true 'SKIPPED (docker not found)'
}

# 5. Dashboard self-test (config wiring) must report 0 FAIL.
$dash = Join-Path $Root 'AI-Dashboard.ps1'
$pwsh = (Get-Process -Id $PID).Path
$stOut = & $pwsh -NoProfile -STA -ExecutionPolicy Bypass -File $dash -SelfTest 2>&1
Add-Result 'Dashboard self-test' ($LASTEXITCODE -eq 0) (("$stOut" -split "`n" | Where-Object { $_ -match 'Summary' } | Select-Object -First 1))

# 6. Regression: the $args automatic-variable footgun. Extract the real
#    Join-ProcessArguments from AI-Dashboard.ps1 and prove it returns a full
#    argument line (an empty string is the symptom of param($args)).
try {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($dash, [ref]$null, [ref]$null)
    $fnAst = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Join-ProcessArguments' }, $true)
    if (-not $fnAst) {
        Add-Result 'Regression: $args footgun' $false 'Join-ProcessArguments not found'
    } else {
        . ([scriptblock]::Create($fnAst.Extent.Text))
        $argLine = Join-ProcessArguments @('-NoProfile', '-File', 'C:\dir with space\s.ps1', '-Flag')
        $ok = (-not [string]::IsNullOrWhiteSpace($argLine)) -and ($argLine -match '-NoProfile') -and ($argLine -match '-Flag') -and ($argLine -match '"C:\\dir with space\\s\.ps1"')
        Add-Result 'Regression: $args footgun' $ok "output='$argLine'"
    }
} catch {
    Add-Result 'Regression: $args footgun' $false $_.Exception.Message
}

# 7. Static analysis: zero Error-severity, and no NEW automatic-variable
#    assignments beyond the known legacy baseline (burndown list in AGENTS.md).
$autoVarBaseline = 0    # all known automatic-variable shadows fixed; any new hit fails the gate.
if ($SkipAnalyzer) {
    Add-Result 'Static analysis' $true 'SKIPPED (-SkipAnalyzer)'
} elseif (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
    Add-Result 'Static analysis' $true 'SKIPPED (PSScriptAnalyzer not installed)'
} else {
    Import-Module PSScriptAnalyzer
    $settings = Join-Path $Root 'PSScriptAnalyzerSettings.psd1'
    $analysis = foreach ($f in $psFiles) { Invoke-ScriptAnalyzer -Path $f.FullName -Settings $settings -ErrorAction SilentlyContinue }
    $errCount = @($analysis | Where-Object Severity -eq 'Error').Count
    Add-Result 'Analyzer: 0 errors' ($errCount -eq 0) "errors=$errCount"
    $autoVar = @($analysis | Where-Object RuleName -eq 'PSAvoidAssignmentToAutomaticVariable').Count
    Add-Result "Analyzer: no new `$args-class (<=$autoVarBaseline)" ($autoVar -le $autoVarBaseline) "current=$autoVar baseline=$autoVarBaseline"
}

# Summary.
$results | Format-Table -AutoSize | Out-String | Write-Host
if ($script:Fail -gt 0) {
    Write-Host "GATE FAILED: $script:Fail check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "GATE PASSED: all checks green." -ForegroundColor Green
exit 0
