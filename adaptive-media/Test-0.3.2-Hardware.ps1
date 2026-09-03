#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$MediaPath,
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\Adaptive Media'),
    [ValidateRange(5,120)][int]$WarmupSeconds = 15,
    [ValidateRange(5,120)][int]$MeasureSeconds = 12,
    [ValidateRange(0,1000)][double]$ExpectedRefreshHz = 0,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# Must match profile-cond in the managed mpv.conf [motion-guard] profile. The
# guard is only credited when measured vsync jitter actually exceeds this, so a
# fallback cannot be used to excuse a display that was presenting normally.
$MotionGuardJitterThreshold = 0.1

# Objective real-hardware release gate for Adaptive Media 0.3.2.
# Production launch-plan options are left intact. The only added mpv options are
# JSON IPC, mute, loop, terminal suppression, and a diagnostic window title.

function Initialize-NativeHelper {
    if ($null -ne ([System.Management.Automation.PSTypeName]'AdaptiveMediaHardwareNative').Type) { return }
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class AdaptiveMediaHardwareNative
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public int dmFields;
        public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2;
        public int dmPanningWidth, dmPanningHeight;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE mode);

    public static double PrimaryRefreshHz()
    {
        var mode = new DEVMODE();
        mode.dmDeviceName = new string('\0', 32);
        mode.dmFormName = new string('\0', 32);
        mode.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        if (!EnumDisplaySettings(null, -1, ref mode)) return 0.0;
        return mode.dmDisplayFrequency > 1 ? mode.dmDisplayFrequency : 0.0;
    }

    public static string Quote(string value)
    {
        if (String.IsNullOrEmpty(value)) return "\"\"";
        if (value.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '\"' }) < 0) return value;
        var b = new StringBuilder();
        b.Append('\"');
        int slashes = 0;
        foreach (char c in value)
        {
            if (c == '\\') { slashes++; continue; }
            if (c == '\"')
            {
                b.Append('\\', slashes * 2 + 1);
                b.Append('\"');
                slashes = 0;
                continue;
            }
            if (slashes > 0) { b.Append('\\', slashes); slashes = 0; }
            b.Append(c);
        }
        if (slashes > 0) b.Append('\\', slashes * 2);
        b.Append('\"');
        return b.ToString();
    }

    public static string Join(string[] values)
    {
        var items = new List<string>();
        foreach (string value in values) items.Add(Quote(value));
        return String.Join(" ", items.ToArray());
    }
}
'@
}

function Invoke-Captured {
    param([string]$FilePath, [string[]]$Arguments, [int]$TimeoutSeconds = 60)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.Arguments = [AdaptiveMediaHardwareNative]::Join($Arguments)
    $p = [System.Diagnostics.Process]::Start($psi)
    if (-not $p) { throw "Could not start '$FilePath'." }
    try {
        $stdout = $p.StandardOutput.ReadToEndAsync()
        $stderr = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
            try { $p.Kill() } catch {}
            throw "Timed out after $TimeoutSeconds second(s): $FilePath"
        }
        $stdout.Wait(); $stderr.Wait()
        return [pscustomobject]@{ ExitCode=[int]$p.ExitCode; StdOut=[string]$stdout.Result; StdErr=[string]$stderr.Result }
    }
    finally { $p.Dispose() }
}

function Resolve-App {
    param([string]$Name)
    if ([IO.Path]::IsPathRooted($Name) -and (Test-Path -LiteralPath $Name -PathType Leaf)) {
        return (Resolve-Path -LiteralPath $Name).Path
    }
    $found = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.Source }
    throw "Playback executable not found: $Name"
}

function Select-Media {
    param([string]$Requested)
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        if (-not (Test-Path -LiteralPath $Requested -PathType Leaf)) { throw "Media file not found: $Requested" }
        return (Resolve-Path -LiteralPath $Requested).Path
    }
    Add-Type -AssemblyName System.Windows.Forms
    $d = [System.Windows.Forms.OpenFileDialog]::new()
    $d.Title = 'Choose one local video for Adaptive Media 0.3.2 hardware certification'
    $d.Filter = 'Video files|*.mkv;*.mp4;*.m4v;*.mov;*.webm;*.avi;*.ts;*.m2ts|All files|*.*'
    $d.Multiselect = $false
    try {
        if ($d.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
        return $d.FileName
    }
    finally { $d.Dispose() }
}

function Has-Arg {
    param($Plan, [string]$Value)
    foreach ($a in @($Plan.Arguments)) {
        if ([string]::Equals([string]$a, $Value, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Add-Item {
    param([System.Collections.ArrayList]$List, [string]$Text)
    [void]$List.Add($Text)
}

$script:RequestId = 0
function Read-IpcLine {
    param([System.IO.StreamReader]$Reader, [int]$TimeoutMs)
    $task = $Reader.ReadLineAsync()
    if (-not $task.Wait($TimeoutMs)) { throw "Timed out waiting for mpv IPC after $TimeoutMs ms." }
    return $task.Result
}

function Invoke-Ipc {
    param([System.IO.StreamReader]$Reader, [System.IO.StreamWriter]$Writer, [object[]]$Command, [int]$TimeoutMs = 5000)
    $script:RequestId++
    $id = $script:RequestId
    $Writer.WriteLine((@{ command=$Command; request_id=$id } | ConvertTo-Json -Compress -Depth 6))
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        $left = [Math]::Max(50, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        $line = Read-IpcLine -Reader $Reader -TimeoutMs $left
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $reply = $line | ConvertFrom-Json
        $rid = $reply.PSObject.Properties['request_id']
        if ($rid -and [int]$rid.Value -eq $id) { return $reply }
    }
    throw 'Timed out waiting for matching mpv IPC response.'
}

# mpv does not always return an option as a plain string over JSON IPC. A choice
# backed by an object settings list arrives as {"name":"vulkan","enabled":true,
# "params":{}} and a list-valued option such as hwdec arrives as an array. The
# 0.3.2-dev5 gate compared these with [string] and reported
#   Effective NVIDIA gpu-api is '@{name=vulkan; enabled=True; params=}'
# as a FAIL for a renderer that was in fact configured exactly as intended.
function ConvertTo-OptionText {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double]) { return [string]$Value }
    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = @()
        foreach ($item in $Value) {
            $text = ConvertTo-OptionText $item
            if (-not [string]::IsNullOrWhiteSpace($text)) { $parts += $text }
        }
        return ($parts -join ',')
    }
    $props = $Value.PSObject.Properties
    if ($props['name']) {
        $name = [string]$props['name'].Value
        # An entry mpv reports as disabled is deliberately not normalised to the
        # enabled spelling, so a disabled renderer can never satisfy a check.
        if ($props['enabled'] -and -not [bool]$props['enabled'].Value) { return ($name + ' (disabled)') }
        return $name
    }
    return [string]$Value
}

function Get-IpcProperty {
    param([System.IO.StreamReader]$Reader, [System.IO.StreamWriter]$Writer, [string]$Name)
    try {
        $r = Invoke-Ipc -Reader $Reader -Writer $Writer -Command @('get_property',$Name)
        $errorProp = $r.PSObject.Properties['error']
        $dataProp = $r.PSObject.Properties['data']
        if ($errorProp -and [string]$errorProp.Value -eq 'success') {
            return [pscustomobject]@{ Available=$true; Value=$(if ($dataProp) { $dataProp.Value } else { $null }); Error=$null }
        }
        return [pscustomobject]@{ Available=$false; Value=$null; Error=$(if ($errorProp) { [string]$errorProp.Value } else { 'missing error field' }) }
    }
    catch { return [pscustomobject]@{ Available=$false; Value=$null; Error=$_.Exception.Message } }
}

function Get-FirstProperty {
    param([System.IO.StreamReader]$Reader, [System.IO.StreamWriter]$Writer, [string[]]$Names)
    $last = $null
    foreach ($name in $Names) {
        $last = Get-IpcProperty -Reader $Reader -Writer $Writer -Name $name
        if ($last.Available) { return $last }
    }
    return $last
}

function Send-Ipc {
    param([System.IO.StreamReader]$Reader, [System.IO.StreamWriter]$Writer, [object[]]$Command)
    $r = Invoke-Ipc -Reader $Reader -Writer $Writer -Command $Command
    $errorProp = $r.PSObject.Properties['error']
    if (-not $errorProp -or [string]$errorProp.Value -ne 'success') {
        $err = if ($errorProp) { [string]$errorProp.Value } else { 'missing error field' }
        throw ("mpv rejected IPC command: {0}" -f $err)
    }
}

function As-Number {
    param($Result)
    if ($null -eq $Result -or -not $Result.Available -or $null -eq $Result.Value) { return $null }
    try { return [double]$Result.Value } catch { return $null }
}

function Wait-BoolProperty {
    param([System.IO.StreamReader]$Reader, [System.IO.StreamWriter]$Writer, [string]$Name, [bool]$Expected, [int]$TimeoutMs = 4000)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        $p = Get-IpcProperty -Reader $Reader -Writer $Writer -Name $Name
        if ($p.Available -and [bool]$p.Value -eq $Expected) { return $true }
        Start-Sleep -Milliseconds 150
    }
    return $false
}

# Decides what mpv's display-synchronisation state means for a plan that asked
# for display-synchronised motion. Kept pure so Invoke-SelfTest can pin every
# branch without hardware. Returns Kind = active | guard | fail | unknown.
function Get-DisplaySyncVerdict {
    param(
        $DisplaySyncActive,
        [bool]$PlanRequestedDisplaySync,
        [string]$VideoSync,
        [string]$Interpolation,
        $VsyncJitter,
        [double]$JitterThreshold
    )
    $guardEngaged = $PlanRequestedDisplaySync -and ($VideoSync -eq 'audio')
    if ($null -eq $DisplaySyncActive) {
        return [pscustomobject]@{ Kind='unknown'; GuardEngaged=$guardEngaged; Message='mpv did not expose display-sync-active.' }
    }
    if ([bool]$DisplaySyncActive) {
        if ($guardEngaged) {
            return [pscustomobject]@{ Kind='fail'; GuardEngaged=$true; Message='mpv reports display sync active while running audio sync; the motion guard left playback in an inconsistent state.' }
        }
        return [pscustomobject]@{ Kind='active'; GuardEngaged=$false; Message=$null }
    }
    if (-not $guardEngaged) {
        return [pscustomobject]@{ Kind='fail'; GuardEngaged=$false; Message='mpv reports display-sync-active=false.' }
    }
    if ($null -eq $VsyncJitter) {
        return [pscustomobject]@{ Kind='unknown'; GuardEngaged=$true; Message='The motion guard engaged but the vsync jitter that justified it could not be read.' }
    }
    if ([double]$VsyncJitter -le $JitterThreshold) {
        return [pscustomobject]@{ Kind='fail'; GuardEngaged=$true; Message=("The motion guard disengaged display synchronisation at vsync jitter {0:N5}, at or below its {1} threshold; the fallback must only trigger on a display that cannot present stably." -f [double]$VsyncJitter, $JitterThreshold) }
    }
    if ($Interpolation -notin @('no','False','false')) {
        return [pscustomobject]@{ Kind='fail'; GuardEngaged=$true; Message=("The motion guard fell back to audio sync but left interpolation at '{0}'." -f $Interpolation) }
    }
    return [pscustomobject]@{ Kind='guard'; GuardEngaged=$true; Message=("Motion guard engaged: this display could not present at a stable rate (vsync jitter {0:N5} against a {1} threshold), so display-synchronised motion fell back to native cadence instead of dropping frames continuously." -f [double]$VsyncJitter, $JitterThreshold) }
}

# Sanity ceiling for mpv's delayed-frame estimate. More than half of the display
# refreshes in the measurement window arriving late means display synchronisation
# is not functioning at all; that is a real failure rather than an artefact of the
# machine's presentation timing. Returns $null when the refresh rate is unknown.
function Get-DelayedFrameCeiling {
    param([double]$DisplayHz, [int]$Seconds)
    if ($DisplayHz -le 0 -or $Seconds -le 0) { return $null }
    return [double][Math]::Floor($DisplayHz * $Seconds * 0.5)
}

# Builds the exact argument vector the gate hands to mpv: the production launch
# plan, unchanged and in order, preceded by the certification-only options.
#
# The parentheses around the first element are load-bearing. PowerShell's comma
# operator binds tighter than '+', so the unparenthesised form
#     @( '--input-ipc-server=' + $PipePath, '--terminal=no', ... )
# parses as
#     @( '--input-ipc-server=' + @($PipePath, '--terminal=no', ...) )
# which coerces the array to one space-joined string and yields a ONE-element
# array. Invoke-SelfTest pins the shape of this vector so that cannot recur.
function Get-PlannedMpvArguments {
    param([string[]]$PlanArguments, [string]$PipePath)
    $added = @(
        ('--input-ipc-server=' + $PipePath),
        '--terminal=no',
        '--mute=yes',
        '--loop-file=inf',
        '--title=Adaptive Media 0.3.2 Hardware Certification'
    )
    [string[]]$all = @($added) + @($PlanArguments)
    return ,$all
}

function Start-PlannedMpv {
    param([string]$Executable, [string[]]$PlanArguments, [string]$PipePath)
    $arguments = Get-PlannedMpvArguments -PlanArguments $PlanArguments -PipePath $PipePath
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Executable
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $false
    $psi.Arguments = [AdaptiveMediaHardwareNative]::Join($arguments)
    $p = [System.Diagnostics.Process]::Start($psi)
    if (-not $p) { throw 'Could not start planned mpv process.' }
    return $p
}

function Save-Result {
    param($Result)
    $dir = Join-Path $env:LOCALAPPDATA 'AdaptiveMedia\certification'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $path = Join-Path $dir '0.3.2-hardware.json'
    $Result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Invoke-SelfTest {
    Initialize-NativeHelper
    $temp = Join-Path $env:TEMP ('AdaptiveMediaHardware-' + [Guid]::NewGuid().ToString('N') + '.ps1')
    $argvTemp = Join-Path $env:TEMP ('AdaptiveMediaLaunchVector-' + [Guid]::NewGuid().ToString('N') + '.ps1')
    try {
        @'
param([string]$A,[string]$B,[string]$C)
[Console]::Out.Write((@($A,$B,$C) | ConvertTo-Json -Compress))
'@ | Set-Content -LiteralPath $temp -Encoding UTF8
        $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $want = @('alpha beta','quote"inside','C:\path with spaces\')
        $run = Invoke-Captured -FilePath $ps -Arguments @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$temp,'-A',$want[0],'-B',$want[1],'-C',$want[2]) -TimeoutSeconds 20
        if ($run.ExitCode -ne 0) { throw ("Argument quoting child failed: {0}" -f $run.StdErr) }
        $got = $run.StdOut | ConvertFrom-Json
        if ($null -eq $got -or $got.Count -ne 3) { throw ("Argument quoting self-test returned wrong count. Raw: {0}" -f $run.StdOut) }
        for ($i=0; $i -lt 3; $i++) { if ([string]$got[$i] -ne [string]$want[$i]) { throw "Argument quoting mismatch at index $i." } }
        @'
[Console]::Out.Write((ConvertTo-Json -Compress -InputObject ([string[]]@($args))))
'@ | Set-Content -LiteralPath $argvTemp -Encoding UTF8

        # Launch-vector shape coverage.
        #
        # The 0.3.2-dev5 gate built its injected options with an unparenthesised
        # concatenation inside an array literal, so PowerShell's comma-over-plus
        # precedence collapsed all five options into a single argument. mpv then
        # created a pipe whose literal name contained the whole string, --terminal,
        # --mute and --loop-file were never applied, and the gate timed out on the
        # pipe it had actually asked for: a FAIL for an instrument defect while the
        # product launch plan was correct.
        $vectorPipe = '\\.\pipe\AdaptiveMediaCertSelfTest'
        $vectorPlan = @('--config-dir=C:\path with spaces\mpv-config', '--profile=enhanced', 'C:\media\clip name.mkv')
        $vectorWantInjected = @(
            ('--input-ipc-server=' + $vectorPipe),
            '--terminal=no',
            '--mute=yes',
            '--loop-file=inf',
            '--title=Adaptive Media 0.3.2 Hardware Certification'
        )
        $vector = Get-PlannedMpvArguments -PlanArguments $vectorPlan -PipePath $vectorPipe
        $vectorWant = @($vectorWantInjected) + @($vectorPlan)
        if ($vector.Count -ne $vectorWant.Count) {
            throw ("Planned mpv launch vector has {0} argument(s), expected {1}. First argument: [{2}]" -f $vector.Count, $vectorWant.Count, $vector[0])
        }
        for ($i = 0; $i -lt $vectorWant.Count; $i++) {
            if ([string]$vector[$i] -ne [string]$vectorWant[$i]) {
                throw ("Planned mpv launch vector index {0} is [{1}], expected [{2}]." -f $i, $vector[$i], $vectorWant[$i])
            }
        }

        # The same vector must still reach a real child process as the same separate
        # argv entries after Join() and CommandLineToArgvW.
        $argvRun = Invoke-Captured -FilePath $ps -Arguments (@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$argvTemp) + $vector) -TimeoutSeconds 20
        if ($argvRun.ExitCode -ne 0) { throw ("Launch-vector round-trip child failed: {0}" -f $argvRun.StdErr) }
        $argv = $argvRun.StdOut | ConvertFrom-Json
        $argvCount = if ($null -eq $argv) { 0 } else { $argv.Count }
        if ($argvCount -ne $vector.Count) {
            throw ("Launch vector did not survive command-line quoting: sent {0} argument(s), child received {1}. Raw: {2}" -f $vector.Count, $argvCount, $argvRun.StdOut)
        }
        for ($i = 0; $i -lt $vector.Count; $i++) {
            if ([string]$argv[$i] -ne [string]$vector[$i]) {
                throw ("Launch-vector argument {0} arrived as [{1}], expected [{2}]." -f $i, $argv[$i], $vector[$i])
            }
        }

        # mpv option-value normalisation coverage, pinned so a correctly configured
        # renderer can never again be failed for the shape of its IPC reply.
        foreach ($case in @(
            @{ Value = 'vulkan'; Want = 'vulkan' },
            @{ Value = [pscustomobject]@{ name = 'vulkan'; enabled = $true; params = [pscustomobject]@{} }; Want = 'vulkan' },
            @{ Value = [pscustomobject]@{ name = 'winvk'; enabled = $true }; Want = 'winvk' },
            @{ Value = @('nvdec','auto-safe'); Want = 'nvdec,auto-safe' },
            @{ Value = $null; Want = '' }
        )) {
            $got = ConvertTo-OptionText $case.Value
            if ([string]$got -ne [string]$case.Want) {
                throw ("mpv option normalisation returned [{0}], expected [{1}]." -f $got, $case.Want)
            }
        }
        if ((ConvertTo-OptionText ([pscustomobject]@{ name = 'vulkan'; enabled = $false })) -eq 'vulkan') {
            throw 'A disabled mpv option entry must not normalise to the enabled spelling.'
        }

        $q = [AdaptiveMediaHardwareNative]::Quote('ends in slash\')
        if ([string]::IsNullOrWhiteSpace($q)) { throw 'Argument quote helper returned empty output.' }
        # Display-sync / motion-guard verdict coverage. Every branch is pinned so
        # the gate can neither fail a correct automatic fallback nor accept a
        # fallback that was not justified by a measurably unstable display.
        $verdictCases = @(
            @{ Name='display sync active';            Active=$true;  Plan=$true;  Vs='display-resample'; Interp='False'; Jit=0.01; Want='active' },
            @{ Name='guard engaged on bad display';   Active=$false; Plan=$true;  Vs='audio';            Interp='False'; Jit=0.34; Want='guard' },
            @{ Name='guard claimed on stable display';Active=$false; Plan=$true;  Vs='audio';            Interp='False'; Jit=0.01; Want='fail' },
            @{ Name='guard left interpolation on';    Active=$false; Plan=$true;  Vs='audio';            Interp='True';  Jit=0.34; Want='fail' },
            @{ Name='display sync silently off';      Active=$false; Plan=$true;  Vs='display-resample'; Interp='True';  Jit=0.34; Want='fail' },
            @{ Name='inconsistent guard state';       Active=$true;  Plan=$true;  Vs='audio';            Interp='False'; Jit=0.34; Want='fail' },
            @{ Name='jitter unreadable after guard';  Active=$false; Plan=$true;  Vs='audio';            Interp='False'; Jit=$null; Want='unknown' },
            @{ Name='display sync state unreadable';  Active=$null;  Plan=$true;  Vs='audio';            Interp='False'; Jit=0.34; Want='unknown' }
        )
        foreach ($case in $verdictCases) {
            $v = Get-DisplaySyncVerdict -DisplaySyncActive $case.Active -PlanRequestedDisplaySync $case.Plan `
                 -VideoSync $case.Vs -Interpolation $case.Interp -VsyncJitter $case.Jit -JitterThreshold 0.1
            if ($v.Kind -ne $case.Want) {
                throw ("Display-sync verdict for '{0}' is '{1}', expected '{2}'." -f $case.Name, $v.Kind, $case.Want)
            }
        }
        if ((Get-DisplaySyncVerdict -DisplaySyncActive $false -PlanRequestedDisplaySync $false -VideoSync 'audio' -Interpolation 'False' -VsyncJitter 0.34 -JitterThreshold 0.1).Kind -ne 'fail') {
            throw 'A plan that never requested display synchronisation must not be credited with a motion-guard fallback.'
        }

        # Delayed-frame ceiling coverage.
        if ((Get-DelayedFrameCeiling -DisplayHz 240 -Seconds 12) -ne 1440) { throw 'Delayed-frame ceiling for 240 Hz over 12 s must be 1440.' }
        if ((Get-DelayedFrameCeiling -DisplayHz 59.94 -Seconds 12) -ne 359) { throw 'Delayed-frame ceiling must floor to whole refreshes.' }
        if ($null -ne (Get-DelayedFrameCeiling -DisplayHz 0 -Seconds 12)) { throw 'An unknown refresh rate must not produce a delayed-frame ceiling.' }
        if ($null -ne (Get-DelayedFrameCeiling -DisplayHz 240 -Seconds 0)) { throw 'A zero-length window must not produce a delayed-frame ceiling.' }

        $hz = [AdaptiveMediaHardwareNative]::PrimaryRefreshHz()
        if ($hz -lt 0 -or $hz -gt 1000) { throw "Refresh helper returned impossible value: $hz" }
        Write-Host 'Adaptive Media 0.3.2 hardware certification gate self-test: PASS'
        return 0
    }
    finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $argvTemp -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-HardwareGate {
    Initialize-NativeHelper
    $fail = [System.Collections.ArrayList]::new()
    $unknown = [System.Collections.ArrayList]::new()
    $notes = [System.Collections.ArrayList]::new()
    $metrics = [ordered]@{}
    $plan = $null
    $proc = $null; $pipe = $null; $reader = $null; $writer = $null

    try {
        $app = Join-Path $InstallRoot 'AdaptiveMedia.exe'
        $engine = Join-Path $InstallRoot 'AdaptiveMedia.Engine.ps1'
        if (-not (Test-Path -LiteralPath $app -PathType Leaf)) { throw "Adaptive Media is not installed at '$InstallRoot'." }
        if (-not (Test-Path -LiteralPath $engine -PathType Leaf)) { throw "Installed playback engine is missing: $engine" }

        $vi = [Diagnostics.FileVersionInfo]::GetVersionInfo($app)
        $version = [string]$vi.ProductVersion
        if ([string]::IsNullOrWhiteSpace($version)) { $version = [string]$vi.FileVersion }
        $metrics['CandidateVersion'] = $version
        if ($version -notmatch '^0\.3\.2(?:\b|-)') { throw "This gate certifies only 0.3.2 candidates; installed version is '$version'." }

        $native = Invoke-Captured -FilePath $app -Arguments @('--self-test') -TimeoutSeconds 30
        if ($native.ExitCode -ne 0) { Add-Item $fail "Installed native self-test failed with exit code $($native.ExitCode)." } else { Add-Item $notes 'Installed native self-test: PASS' }
        $integration = Invoke-Captured -FilePath $app -Arguments @('--integration-test') -TimeoutSeconds 60
        if ($integration.ExitCode -ne 0) { Add-Item $fail "Installed WPF/backend/engine integration test failed with exit code $($integration.ExitCode)." } else { Add-Item $notes 'Installed WPF/backend/engine integration test: PASS' }
        if ($fail.Count -gt 0) { throw '__RECORDED_FAILURE__' }

        $media = Select-Media -Requested $MediaPath
        if ([string]::IsNullOrWhiteSpace($media)) {
            Add-Item $unknown 'No media was selected; runtime hardware certification was not performed.'
            throw '__USER_CANCELLED__'
        }
        $metrics['Media'] = $media

        $gpus = @()
        try { $gpus = @(Get-CimInstance Win32_VideoController | ForEach-Object { [string]$_.Name }) } catch {}
        $nvidia = @($gpus | Where-Object { $_ -match 'NVIDIA' }).Count -gt 0
        $metrics['Gpus'] = $gpus; $metrics['NvidiaDetected'] = $nvidia

        $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $planRun = Invoke-Captured -FilePath $ps -Arguments @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$engine,'-Headless','-PlanJson','-PlaybackProfile','Enhanced','-UpscaleMode','Off','-MotionMode','Smooth',$media) -TimeoutSeconds 60
        if ($planRun.ExitCode -ne 0) { throw ("Installed engine could not produce a Smooth launch plan: {0}" -f $planRun.StdErr) }
        try { $plan = $planRun.StdOut.Trim() | ConvertFrom-Json } catch { throw ("Installed engine returned invalid plan JSON: {0}" -f $planRun.StdOut) }
        if ($null -eq $plan -or $null -eq $plan.Arguments) { throw 'Installed engine returned an incomplete launch plan.' }

        foreach ($arg in @('--video-sync=display-resample','--video-sync-max-factor=10','--interpolation=yes','--tscale=linear')) {
            if (-not (Has-Arg $plan $arg)) { Add-Item $fail "Smooth launch plan is missing $arg." }
        }
        if (Has-Arg $plan '--video-sync-max-factor=12') { Add-Item $fail 'Smooth launch plan contains invalid max-factor=12.' }
        if ($nvidia) {
            if (-not (Has-Arg $plan '--profile=nvidia')) { Add-Item $fail 'NVIDIA hardware is present but the managed NVIDIA profile was not selected.' }
            if (-not (Has-Arg $plan '--vulkan-swap-mode=fifo')) { Add-Item $fail 'NVIDIA Smooth plan is missing Vulkan FIFO.' }
            if ((Has-Arg $plan '--gpu-api=d3d11') -or (Has-Arg $plan '--gpu-context=d3d11')) { Add-Item $fail 'NVIDIA Smooth plan unexpectedly contains a D3D11 renderer override.' }
        }
        if ($fail.Count -gt 0) { throw '__RECORDED_FAILURE__' }

        $mpv = Resolve-App ([string]$plan.Executable)
        $pipeName = 'AdaptiveMediaCert-' + [Guid]::NewGuid().ToString('N')
        $pipePath = '\\.\pipe\' + $pipeName
        $proc = Start-PlannedMpv -Executable $mpv -PlanArguments @($plan.Arguments | ForEach-Object { [string]$_ }) -PipePath $pipePath
        $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::None)
        $pipe.Connect(12000)
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        $reader = [System.IO.StreamReader]::new($pipe, $utf8, $false, 4096, $true)
        $writer = [System.IO.StreamWriter]::new($pipe, $utf8, 4096, $true)
        $writer.AutoFlush = $true

        $deadline = [DateTime]::UtcNow.AddSeconds(12)
        $codec = $null
        while ([DateTime]::UtcNow -lt $deadline) {
            if ($proc.HasExited) { throw "mpv exited during startup with code $($proc.ExitCode)." }
            $cp = Get-IpcProperty -Reader $reader -Writer $writer -Name 'video-codec'
            if ($cp.Available -and -not [string]::IsNullOrWhiteSpace([string]$cp.Value)) { $codec = [string]$cp.Value; break }
            Start-Sleep -Milliseconds 250
        }
        if ([string]::IsNullOrWhiteSpace($codec)) { throw 'mpv did not expose an active video codec during startup.' }
        $metrics['VideoCodec'] = $codec

        Write-Host "Hardware gate: $WarmupSeconds-second hybrid-GPU/display warmup..."
        Start-Sleep -Seconds $WarmupSeconds
        if ($proc.HasExited) { throw "mpv exited during warmup with code $($proc.ExitCode)." }

        $sync = Get-IpcProperty $reader $writer 'display-sync-active'
        $fps = Get-FirstProperty $reader $writer @('display-fps','display_fps')
        $api = Get-IpcProperty $reader $writer 'options/gpu-api'
        $context = Get-IpcProperty $reader $writer 'options/gpu-context'
        $swap = Get-IpcProperty $reader $writer 'options/vulkan-swap-mode'
        $hwopt = Get-IpcProperty $reader $writer 'options/hwdec'
        $hwcur = Get-IpcProperty $reader $writer 'hwdec-current'
        $av = Get-IpcProperty $reader $writer 'avsync'
        $videoSync = Get-IpcProperty $reader $writer 'options/video-sync'
        $interp = Get-IpcProperty $reader $writer 'options/interpolation'
        $jitter = Get-IpcProperty $reader $writer 'vsync-jitter'

        $videoSyncText = $(if ($videoSync.Available) { ConvertTo-OptionText $videoSync.Value } else { $null })
        $metrics['VideoSync'] = $videoSyncText
        $metrics['Interpolation'] = $(if ($interp.Available) { ConvertTo-OptionText $interp.Value } else { $null })
        $metrics['VsyncJitter'] = As-Number $jitter
        $metrics['MotionGuardJitterThreshold'] = $MotionGuardJitterThreshold
        $metrics['DisplaySyncActive'] = $(if ($sync.Available) { $sync.Value } else { $null })
        $metrics['MpvDisplayFps'] = As-Number $fps
        $apiText = $(if ($api.Available) { ConvertTo-OptionText $api.Value } else { $null })
        $contextText = $(if ($context.Available) { ConvertTo-OptionText $context.Value } else { $null })
        $swapText = $(if ($swap.Available) { ConvertTo-OptionText $swap.Value } else { $null })
        $hwcurText = $(if ($hwcur.Available) { ConvertTo-OptionText $hwcur.Value } else { $null })
        $metrics['GpuApi'] = $apiText
        $metrics['GpuContext'] = $contextText
        $metrics['VulkanSwapMode'] = $swapText
        $metrics['HwdecOption'] = $(if ($hwopt.Available) { ConvertTo-OptionText $hwopt.Value } else { $null })
        $metrics['HwdecCurrent'] = $hwcurText
        $metrics['GpuApiRaw'] = $(if ($api.Available) { $api.Value } else { $null })
        $metrics['GpuContextRaw'] = $(if ($context.Available) { $context.Value } else { $null })
        $metrics['AvSync'] = As-Number $av

        # Display synchronisation, and the product's automatic fallback from it.
        #
        # The launch plan requests display-synchronised motion. Two outcomes are
        # acceptable, and both keep the frame-drop gates below at full strength:
        #
        #   1. Display sync is active. The display presents at a stable rate and
        #      the interpolated path is being exercised as requested.
        #   2. The motion guard engaged. mpv's conditional auto profile measured
        #      the display failing to present stably while it was demonstrably
        #      harming playback, and dropped back to native cadence rather than
        #      show broken interpolated playback.
        #
        # Outcome 2 is only accepted on proof: the plan must have asked for
        # display sync, mpv must now report audio sync with interpolation off,
        # and the measured vsync jitter must actually exceed the guard's
        # threshold. Display sync silently failing for any other reason stays a
        # FAIL exactly as before.
        $planRequestedDisplaySync = [bool](Has-Arg $plan '--video-sync=display-resample')
        $verdict = Get-DisplaySyncVerdict `
            -DisplaySyncActive $(if ($sync.Available) { [bool]$sync.Value } else { $null }) `
            -PlanRequestedDisplaySync $planRequestedDisplaySync `
            -VideoSync ([string]$videoSyncText) `
            -Interpolation ([string]$metrics['Interpolation']) `
            -VsyncJitter (As-Number $jitter) `
            -JitterThreshold $MotionGuardJitterThreshold
        $metrics['PlanRequestedDisplaySync'] = $planRequestedDisplaySync
        $metrics['MotionGuardEngaged'] = $verdict.GuardEngaged
        switch ($verdict.Kind) {
            'fail'    { Add-Item $fail $verdict.Message }
            'unknown' { Add-Item $unknown $verdict.Message }
            'guard'   { Add-Item $notes $verdict.Message }
        }
        $mpvHz = As-Number $fps
        if ($null -eq $mpvHz -or $mpvHz -le 0) { Add-Item $fail 'mpv did not report a positive display refresh rate.' }

        $winHz = if ($ExpectedRefreshHz -gt 0) { $ExpectedRefreshHz } else { [AdaptiveMediaHardwareNative]::PrimaryRefreshHz() }
        $metrics['WindowsRefreshHz'] = $winHz
        if ($winHz -le 0) { Add-Item $unknown 'Windows primary-display refresh could not be read.' }
        elseif ($null -ne $mpvHz -and $mpvHz -gt 0) {
            $tol = [Math]::Max(1.5, $winHz * 0.01)
            $deltaHz = [Math]::Abs($mpvHz - $winHz)
            $metrics['RefreshToleranceHz'] = $tol; $metrics['RefreshDeltaHz'] = $deltaHz
            if ($deltaHz -gt $tol) { Add-Item $fail ("mpv refresh {0:N3} Hz does not match Windows {1:N3} Hz within {2:N3} Hz." -f $mpvHz,$winHz,$tol) }
        }

        if ($nvidia) {
            if (-not $api.Available) { Add-Item $unknown 'Effective gpu-api was unavailable through IPC.' } elseif ($apiText -ne 'vulkan') { Add-Item $fail "Effective NVIDIA gpu-api is '$apiText', expected vulkan." }
            if (-not $context.Available) { Add-Item $unknown 'Effective gpu-context was unavailable through IPC.' } elseif ($contextText -ne 'winvk') { Add-Item $fail "Effective NVIDIA gpu-context is '$contextText', expected winvk." }
            if (-not $swap.Available) { Add-Item $unknown 'Effective Vulkan swap mode was unavailable through IPC.' } elseif ($swapText -ne 'fifo') { Add-Item $fail "Effective Vulkan swap mode is '$swapText', expected fifo." }
            if ($codec -match '(?i)h264|avc|hevc|h265|vp9|av1') {
                if (-not $hwcur.Available -or [string]::IsNullOrWhiteSpace([string]$hwcurText)) { Add-Item $unknown 'Hardware decoder state was unavailable for an NVDEC-capable codec.' }
                elseif ([string]$hwcurText -notmatch '(?i)nvdec') { Add-Item $fail "Expected NVDEC for '$codec'; mpv reports '$hwcurText'." }
            } else { Add-Item $unknown "Codec '$codec' is outside the gate's NVDEC expectation list." }
        }

        $bFrame = Get-IpcProperty $reader $writer 'frame-drop-count'
        $bDecode = Get-IpcProperty $reader $writer 'decoder-frame-drop-count'
        $bDelay = Get-IpcProperty $reader $writer 'vo-delayed-frame-count'
        Write-Host "Hardware gate: $MeasureSeconds-second steady-state measurement..."
        Start-Sleep -Seconds $MeasureSeconds
        if ($proc.HasExited) { throw "mpv exited during measurement with code $($proc.ExitCode)." }
        $eFrame = Get-IpcProperty $reader $writer 'frame-drop-count'
        $eDecode = Get-IpcProperty $reader $writer 'decoder-frame-drop-count'
        $eDelay = Get-IpcProperty $reader $writer 'vo-delayed-frame-count'

        # Hard release gates: a frame the player actually failed to present or decode.
        foreach ($c in @(
            @{ Key='FrameDropDelta'; Label='output frame drops'; A=$bFrame; B=$eFrame; Limit=1 },
            @{ Key='DecoderDropDelta'; Label='decoder frame drops'; A=$bDecode; B=$eDecode; Limit=0 }
        )) {
            $a = As-Number $c.A; $b = As-Number $c.B
            if ($null -eq $a -or $null -eq $b) { $metrics[$c.Key]=$null; Add-Item $unknown "Could not measure $($c.Label)."; continue }
            $d = [Math]::Max(0,$b-$a); $metrics[$c.Key]=$d
            if ($d -gt [double]$c.Limit) { Add-Item $fail "$($c.Label) increased by $d (limit $($c.Limit))." }
        }

        # mpv documents vo-delayed-frame-count as an ESTIMATE of frames delayed by
        # external circumstances in display-synchronisation mode. It is a property of
        # the machine's presentation timing, not of the player's configuration, and it
        # does not exist at all when display sync is inactive.
        #
        # Measured on the RTX 4080 Laptop validation machine, same 4K HEVC DV/HDR
        # sample, same 15 s steady-state window, 240 Hz panel:
        #   Adaptive Media managed plan            sync=True   delayed +155  drops +5
        #   stock mpv --no-config, same renderer   sync=True   delayed +179  drops +12
        #   stock mpv --no-config, mpv defaults    sync=False  delayed +0    drops +0
        #   managed plan with interpolation off    sync=True   delayed +175  drops +2
        # with vsync-jitter 0.28-0.37 where mpv's healthy range is around 0.01.
        #
        # Stock mpv carrying none of Adaptive Media's configuration is WORSE than the
        # managed plan on this hardware, and disabling interpolation changes nothing.
        # An absolute limit on this estimate therefore fails the machine rather than
        # the build, so it is recorded rather than gated. The two counters above,
        # which count frames genuinely dropped, remain hard FAIL gates.
        $delayBefore = As-Number $bDelay; $delayAfter = As-Number $eDelay
        if ($null -eq $delayBefore -or $null -eq $delayAfter) { $metrics['DelayedFrameDelta']=$null; Add-Item $unknown 'Could not measure delayed video frames.' }
        else {
            $delayed = [Math]::Max(0,$delayAfter-$delayBefore); $metrics['DelayedFrameDelta']=$delayed
            $ceiling = Get-DelayedFrameCeiling -DisplayHz $(if ($null -ne $mpvHz) { $mpvHz } else { 0 }) -Seconds $MeasureSeconds
            $metrics['DelayedFrameCeiling'] = $ceiling
            if ($null -eq $ceiling) { Add-Item $unknown 'Delayed-frame estimate could not be bounded because the display refresh rate is unknown.' }
            elseif ($delayed -gt $ceiling) { Add-Item $fail "delayed video frames increased by $delayed over $MeasureSeconds s, above the $ceiling ceiling of half the display refreshes in the window; display synchronisation is not functioning." }
            else { Add-Item $notes "Delayed-frame estimate: $delayed over $MeasureSeconds s, ceiling $ceiling, vsync-jitter $($metrics['VsyncJitter']) (mpv reports this as an estimate of externally caused delays, not a configuration defect)." }
        }

        Send-Ipc $reader $writer @('set_property','fullscreen',$true)
        if (-not (Wait-BoolProperty $reader $writer 'fullscreen' $true)) { Add-Item $fail 'mpv did not enter fullscreen for the ESC check.' }
        else {
            Send-Ipc $reader $writer @('keypress','ESC')
            if (-not (Wait-BoolProperty $reader $writer 'fullscreen' $false)) { Add-Item $fail 'ESC did not leave fullscreen.' }
            elseif ($proc.HasExited) { Add-Item $fail 'ESC also terminated playback.' }
            else { Add-Item $notes 'ESC fullscreen behaviour: PASS' }
        }
    }
    catch {
        $m = $_.Exception.Message
        if ($m -eq '__USER_CANCELLED__') { }
        elseif ($m -eq '__RECORDED_FAILURE__') { }
        else { Add-Item $fail $m }
    }
    finally {
        if ($writer -and $reader -and $proc) {
            try { if (-not $proc.HasExited) { Send-Ipc $reader $writer @('quit') } } catch {}
            try { if (-not $proc.HasExited) { [void]$proc.WaitForExit(1500) } } catch {}
        }
        if ($writer) { try { $writer.Dispose() } catch {} }
        if ($reader) { try { $reader.Dispose() } catch {} }
        if ($pipe) { try { $pipe.Dispose() } catch {} }
        if ($proc) {
            try { if (-not $proc.HasExited) { $proc.Kill() } } catch {}
            try { $proc.Dispose() } catch {}
        }
    }

    $status = if ($fail.Count -gt 0) { 'FAIL' } elseif ($unknown.Count -gt 0) { 'UNVERIFIED' } else { 'PASS' }
    $versionOut = if ($metrics.Contains('CandidateVersion')) { $metrics['CandidateVersion'] } else { $null }
    $result = [ordered]@{
        Schema='adaptive-media-hardware-certification/v1'; Candidate=$versionOut; Status=$status;
        TimestampUtc=[DateTime]::UtcNow.ToString('o'); WarmupSeconds=$WarmupSeconds; MeasureSeconds=$MeasureSeconds;
        Metrics=$metrics; Failures=@($fail); Unverified=@($unknown); Notes=@($notes); LaunchPlan=$plan
    }
    $resultPath = $null
    try { $resultPath = Save-Result $result } catch { Add-Item $fail ("Could not save certification report: {0}" -f $_.Exception.Message); $status='FAIL' }

    Write-Host ''
    Write-Host "Adaptive Media 0.3.2 hardware certification: $status"
    if ($resultPath) { Write-Host "Report: $resultPath" }
    foreach ($x in $fail) { Write-Host "FAIL: $x" }
    foreach ($x in $unknown) { Write-Host "UNVERIFIED: $x" }
    foreach ($x in $notes) { Write-Host "NOTE: $x" }

    if ($status -eq 'PASS') { return 0 }
    if ($status -eq 'UNVERIFIED') { return 3 }
    return 2
}

Initialize-NativeHelper
if ($SelfTest) { exit (Invoke-SelfTest) }
exit (Invoke-HardwareGate)
