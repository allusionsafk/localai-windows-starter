# Adaptive Media permanent updater shim.
# Compatibility markers used by RUN-THIS-AdaptiveMedia-Dev.cmd:
# StartupObject>AdaptiveMedia.Program
# App.xaml already generates the AdaptiveMedia.App type
# v0.3.0-dev6
# Current workspace build generation: v0.3.0-dev8

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$work = Join-Path $env:LOCALAPPDATA 'AdaptiveMediaDev'
$log = Join-Path $work 'last-build.log'
$remote = 'https://raw.githubusercontent.com/allusionsafk/localai-windows-starter/adaptive-media-dev/AdaptiveMedia-WorkspaceUpdate.ps1?cb=' + [DateTime]::UtcNow.Ticks
$local = Join-Path $env:TEMP 'AdaptiveMedia-WorkspaceUpdate-LATEST.ps1'

try {
    New-Item -ItemType Directory -Force $work | Out-Null
    Set-Content -LiteralPath $log -Value ("Adaptive Media bootstrap started: " + (Get-Date -Format o)) -Encoding UTF8

    Remove-Item -Force $local -ErrorAction SilentlyContinue
    Invoke-WebRequest -UseBasicParsing -Headers @{'Cache-Control'='no-cache'} -Uri $remote -OutFile $local

    if (-not (Select-String -LiteralPath $local -Pattern 'workspace repair \+ build' -Quiet)) {
        throw 'Downloaded workspace updater did not contain the expected generation marker.'
    }
    if (-not (Select-String -LiteralPath $local -Pattern 'v0.3.0-dev8' -Quiet)) {
        throw 'Downloaded workspace updater was not the expected dev8 generation.'
    }

    # Parse-check before execution. This catches updater syntax errors before
    # PowerShell can fail at process startup, and records the exact parser
    # diagnostics in the same log the user already knows how to upload.
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $local,
        [ref]$tokens,
        [ref]$parseErrors
    )

    if ($parseErrors.Count -gt 0) {
        Add-Content -LiteralPath $log -Value 'Workspace updater parse check: FAILED' -Encoding UTF8
        foreach ($e in $parseErrors) {
            $line = "Line $($e.Extent.StartLineNumber), column $($e.Extent.StartColumnNumber): $($e.Message)"
            Add-Content -LiteralPath $log -Value $line -Encoding UTF8
            Write-Host $line -ForegroundColor Red
        }
        throw 'Downloaded workspace updater failed PowerShell syntax validation.'
    }

    Add-Content -LiteralPath $log -Value 'Workspace updater parse check: PASS' -Encoding UTF8
    Write-Host 'Workspace updater parse check: PASS' -ForegroundColor Green

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $local
    exit $LASTEXITCODE
}
catch {
    Write-Host ''
    Write-Host 'Adaptive Media updater bootstrap FAILED.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Add-Content -LiteralPath $log -Value ('BOOTSTRAP FAILED: ' + $_.Exception.Message) -Encoding UTF8
    Write-Host ''
    Write-Host "This run updated the log: $log" -ForegroundColor Yellow
    Write-Host 'The existing source workspace was not deleted.' -ForegroundColor Yellow
    Read-Host 'Press Enter to close'
    exit 1
}
