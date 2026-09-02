#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot
)

$ErrorActionPreference = 'Stop'

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

$enginePath = Join-Path $SourceRoot 'payload\AdaptiveMedia.Engine.ps1'
$programPath = Join-Path $SourceRoot 'src\AdaptiveMedia.App\Program.cs'
if (-not (Test-Path -LiteralPath $enginePath)) { throw "Engine not found: $enginePath" }
if (-not (Test-Path -LiteralPath $programPath)) { throw "Program.cs not found: $programPath" }

$engine = [IO.File]::ReadAllText($enginePath)

# In PlanJson mode the JSON object must remain stdout. `return 0` is function
# pipeline output in PowerShell and was being captured together with the JSON.
$planPattern = '(?s)(if \(\$PlanJson\) \{\s*\[pscustomobject\]@\{.*?ConvertTo-Json -Depth 5 -Compress\s*try \{ Restore-HdrPolicy \$hdrToken \} catch \{\}\s*if \(\$playlist\) \{ Remove-Item -LiteralPath \$playlist -Force -ErrorAction SilentlyContinue \}\s*)return 0(\s*\}\s*try \{)'
$planReplacement = '$1return$2'
$patchedEngine = [regex]::Replace($engine, $planPattern, $planReplacement, 1)
if ($patchedEngine -eq $engine) { throw 'PlanJson numeric-return hotfix did not match the reviewed stable engine source.' }
$engine = $patchedEngine

# Dispatch PlanJson without assigning Play-MediaHeadless output to $code, otherwise
# the WPF BackendBridge receives no JSON to deserialize.
$headPattern = '(?ms)^if \(\$Headless\) \{\s*\$code = Play-MediaHeadless @\(\$LaunchItems\) \$PlaybackProfile \$UpscaleMode \$MotionMode \(\[bool\]\$Cleanup\) \(\[bool\]\$RtxHdr\) \$YtdlFormat\s*exit \$code\s*\}'
$headReplacement = @'
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
$patchedEngine = [regex]::Replace($engine, $headPattern, $headReplacement, 1)
if ($patchedEngine -eq $engine) { throw 'Headless PlanJson dispatch hotfix did not match the reviewed stable engine source.' }
$engine = $patchedEngine
Write-Utf8NoBom $enginePath $engine

# Make any remaining integration failure self-diagnosing in Actions logs.
$program = [IO.File]::ReadAllText($programPath)
$catchPattern = '(?ms)^\s{8}catch\s*\{\s*return 29;\s*\}'
$catchReplacement = @'
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex);
            return 29;
        }
'@
$patchedProgram = [regex]::Replace($program, $catchPattern, $catchReplacement, 1)
if ($patchedProgram -ne $program) { Write-Utf8NoBom $programPath $patchedProgram }

$verify = [IO.File]::ReadAllText($enginePath)
if ($verify -notmatch '(?ms)^if \(\$Headless\) \{\s*if \(\$PlanJson\)') {
    throw 'Stable headless PlanJson dispatch verification failed after hotfix.'
}
if ($verify -match '(?s)if \(\$PlanJson\) \{\s*\[pscustomobject\]@\{.*?ConvertTo-Json.*?return 0\s*\}\s*try \{') {
    throw 'PlanJson numeric pipeline return remains after hotfix.'
}

Write-Host 'Stable headless launch-plan integration hotfix applied and verified.'
