#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot
)

$ErrorActionPreference = 'Stop'

function Read-Normalized([string]$Path) {
    return ([IO.File]::ReadAllText($Path) -replace "`r`n", "`n")
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

$enginePath = Join-Path $SourceRoot 'payload\AdaptiveMedia.Engine.ps1'
$programPath = Join-Path $SourceRoot 'src\AdaptiveMedia.App\Program.cs'

if (-not (Test-Path -LiteralPath $enginePath)) { throw "Engine not found: $enginePath" }
if (-not (Test-Path -LiteralPath $programPath)) { throw "Program.cs not found: $programPath" }

$engine = Read-Normalized $enginePath

$oldPlan = @'
    if ($PlanJson) {
        [pscustomobject]@{
            Executable = $mpv
            Arguments = @($mpvArgs)
            Profile = $profile
            UpscaleMode = $RequestedUpscale
            MotionMode = $RequestedMotion
            Cleanup = $DoCleanup
            RtxHdr = $DoRtxHdr
        } | ConvertTo-Json -Depth 5 -Compress
        try { Restore-HdrPolicy $hdrToken } catch {}
        if ($playlist) { Remove-Item -LiteralPath $playlist -Force -ErrorAction SilentlyContinue }
        return 0
    }
'@

$newPlan = @'
    if ($PlanJson) {
        [pscustomobject]@{
            Executable = $mpv
            Arguments = @($mpvArgs)
            Profile = $profile
            UpscaleMode = $RequestedUpscale
            MotionMode = $RequestedMotion
            Cleanup = $DoCleanup
            RtxHdr = $DoRtxHdr
        } | ConvertTo-Json -Depth 5 -Compress
        try { Restore-HdrPolicy $hdrToken } catch {}
        if ($playlist) { Remove-Item -LiteralPath $playlist -Force -ErrorAction SilentlyContinue }
        # PlanJson writes exactly one JSON object to stdout. A numeric return value
        # would become PowerShell pipeline output and capture/corrupt that contract.
        return
    }
'@

if (-not $engine.Contains($oldPlan)) { throw 'Expected PlanJson block was not found in stable engine source.' }
$engine = $engine.Replace($oldPlan, $newPlan)

$oldHeadless = @'
if ($Headless) {
    $code = Play-MediaHeadless @($LaunchItems) $PlaybackProfile $UpscaleMode $MotionMode ([bool]$Cleanup) ([bool]$RtxHdr) $YtdlFormat
    exit $code
}
'@

$newHeadless = @'
if ($Headless) {
    if ($PlanJson) {
        # Preserve launch-plan JSON on stdout for the compiled WPF BackendBridge.
        Play-MediaHeadless @($LaunchItems) $PlaybackProfile $UpscaleMode $MotionMode ([bool]$Cleanup) ([bool]$RtxHdr) $YtdlFormat
        exit 0
    }
    $code = Play-MediaHeadless @($LaunchItems) $PlaybackProfile $UpscaleMode $MotionMode ([bool]$Cleanup) ([bool]$RtxHdr) $YtdlFormat
    exit [int]$code
}
'@

if (-not $engine.Contains($oldHeadless)) { throw 'Expected headless dispatch block was not found in stable engine source.' }
$engine = $engine.Replace($oldHeadless, $newHeadless)
Write-Utf8NoBom $enginePath $engine

$program = Read-Normalized $programPath
$oldCatch = @'
        catch
        {
            return 29;
        }
'@
$newCatch = @'
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex);
            return 29;
        }
'@
if ($program.Contains($oldCatch)) {
    $program = $program.Replace($oldCatch, $newCatch)
    Write-Utf8NoBom $programPath $program
}

# Fail closed if the intended source semantics are not now present.
$verifyEngine = Read-Normalized $enginePath
if ($verifyEngine.Contains('return 0' + "`n    }" + "`n`n    try {") ) {
    throw 'PlanJson numeric pipeline return still present after hotfix.'
}
if (-not $verifyEngine.Contains('if ($PlanJson) {' + "`n        # Preserve launch-plan JSON on stdout")) {
    throw 'Headless PlanJson dispatch verification failed after hotfix.'
}

Write-Host 'Stable headless launch-plan integration hotfix applied and verified.'
