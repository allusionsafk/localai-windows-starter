param([string]$Dir = (Get-Location).Path)
# Refresh PATH from the registry so opencode/node resolve even when this terminal
# inherited a stale pre-install PATH from Explorer (no reboot needed).
$env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
            [System.Environment]::GetEnvironmentVariable('Path','User')
if (Test-Path -LiteralPath $Dir) { Set-Location -LiteralPath $Dir }
Write-Host ''
Write-Host 'AI Code Agent (opencode) - it asks before edits/commands. Type /exit to quit.' -ForegroundColor Cyan
Write-Host ''
opencode
