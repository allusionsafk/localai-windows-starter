#requires -Version 5.1
# Real-media regression for the 0.3.2 root cause: a suppressed probe returned no
# dimensions, so the requested RTX VPP filter was never constructed. Runs the
# shipped compatibility entry point on every installed PowerShell runtime,
# because the installer and the app both invoke Windows PowerShell 5.1.
param(
    [Parameter(Mandatory=$true)][string]$Engine,
    [Parameter(Mandatory=$true)][string]$MediaPath,
    [switch]$SkipUnicodePath
)
$ErrorActionPreference = 'Stop'
$Engine = (Resolve-Path -LiteralPath $Engine).Path
$MediaPath = (Resolve-Path -LiteralPath $MediaPath).Path

$runtimes = @()
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (Test-Path -LiteralPath $windowsPowerShell) { $runtimes += ,@('Windows PowerShell 5.1', $windowsPowerShell) }
$pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if ($pwsh) { $runtimes += ,@('PowerShell 7', $pwsh.Source) }
if (-not $runtimes.Count) { throw 'No PowerShell runtime was found to exercise the engine.' }

$media = @(,@('ASCII path', $MediaPath))
$scratch = $null
if (-not $SkipUnicodePath) {
    # The engine writes the request over a redirected stream; a code-page
    # dependent writer corrupts non-ASCII paths before the app ever probes them.
    $scratch = Join-Path $env:TEMP ('AdaptiveMedia-RealProbe-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $scratch | Out-Null
    # Built from code points: Windows PowerShell 5.1 reads a BOM-less UTF-8 script
    # as ANSI, so a literal here would differ between the two runtimes.
    $name = 'probe ' + [char]0x65E5 + [char]0x672C + [char]0x8A9E + "'s (cut) [1]"
    $unicode = Join-Path $scratch ($name + [IO.Path]::GetExtension($MediaPath))
    Copy-Item -LiteralPath $MediaPath -Destination $unicode -Force
    $media += ,@('Non-ASCII path', $unicode)
}
try {
    foreach ($runtime in $runtimes) {
        foreach ($case in $media) {
            $json = & $runtime[1] -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Engine `
                -Headless -PlanJson -PlaybackProfile Enhanced -UpscaleMode RtxVsr $case[1]
            if ($LASTEXITCODE -ne 0) { throw ("Engine plan failed on {0} ({1})." -f $runtime[0], $case[0]) }
            $plan = ($json -join '') | ConvertFrom-Json
            if ($plan.Source.Width -le 0 -or $plan.Source.Height -le 0) {
                throw ("REGRESSION: real media probe returned no dimensions on {0} ({1})." -f $runtime[0], $case[0])
            }
            if ($plan.Arguments[-1] -ne $case[1]) {
                throw ("REGRESSION: the media path did not survive the request on {0} ({1})." -f $runtime[0], $case[0])
            }
            if (-not @($plan.Arguments | Where-Object { $_ -like '--vf=*d3d11vpp=*scaling-mode=nvidia*' }).Count) {
                throw ("REGRESSION: real {0}x{1} probe did not produce the requested RTX VPP argument on {2} ({3})." -f `
                    $plan.Source.Width, $plan.Source.Height, $runtime[0], $case[0])
            }
            Write-Output ("Real-file RTX probe regression on {0} ({1}): PASS" -f $runtime[0], $case[0])
        }
    }
} finally {
    if ($scratch -and (Test-Path -LiteralPath $scratch)) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}
