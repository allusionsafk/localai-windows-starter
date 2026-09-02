# Adaptive Media permanent updater shim.
# Compatibility markers used by RUN-THIS-AdaptiveMedia-Dev.cmd:
# StartupObject>AdaptiveMedia.Program
# App.xaml already generates the AdaptiveMedia.App type
# v0.3.0-dev6
# Current workspace build generation: v0.3.0-dev7

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$remote = 'https://raw.githubusercontent.com/allusionsafk/localai-windows-starter/adaptive-media-dev/AdaptiveMedia-WorkspaceUpdate.ps1?cb=' + [DateTime]::UtcNow.Ticks
$local = Join-Path $env:TEMP 'AdaptiveMedia-WorkspaceUpdate-LATEST.ps1'

try {
    Remove-Item -Force $local -ErrorAction SilentlyContinue
    Invoke-WebRequest -UseBasicParsing -Headers @{'Cache-Control'='no-cache'} -Uri $remote -OutFile $local
    if (-not (Select-String -LiteralPath $local -Pattern 'workspace repair \+ build' -Quiet)) {
        throw 'Downloaded workspace updater did not contain the expected generation marker.'
    }
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $local
    exit $LASTEXITCODE
}
catch {
    Write-Host ''
    Write-Host 'Adaptive Media updater bootstrap FAILED.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ''
    Write-Host 'The existing source workspace was not changed.' -ForegroundColor Yellow
    Read-Host 'Press Enter to close'
    exit 1
}
