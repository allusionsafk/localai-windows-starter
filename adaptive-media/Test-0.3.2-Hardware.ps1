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

# Adaptive Media 0.3.2 hardware certification gate.
# This script does not alter production playback settings. It obtains the launch
# plan from the installed WPF/backend/engine stack and starts that exact plan with
# only mute/loop/IPC instrumentation added so runtime state can be measured.

function Add-HardwareHelperType {
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
        public short dmSpecVersion;
        public short dmDriverVersion;
        public short dmSize;
        public short dmDriverExtra;
        public int dmFields;
        public int dmPositionX;
        public int dmPositionY;
        public int dmDisplayOrientation;
        public int dmDisplayFixedOutput;
        public short dmColor;
        public short dmDuplex;
        public short dmYResolution;
        public short dmTTOption;
        public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel;
        public int dmPelsWidth;
        public int dmPelsHeight;
        public int dmDisplayFlags;
        public int dmDisplayFrequency;
        public int dmICMMethod;
        public int dmICMIntent;
        public int dmMediaType;
        public int dmDitherType;
        public int dmReserved1;
        public int dmReserved2;
        public int dmPanningWidth;
        public int dmPanningHeight;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);

    public static double GetPrimaryRefreshHz()
    {
        DEVMODE mode = new DEVMODE();
        mode.dmDeviceName = new string('\0', 32);
        mode.dmFormName = new string('\0', 32);
        mode.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        if (!EnumDisplaySettings(null, -1, ref mode)) return 0.0;
        return mode.dmDisplayFrequency > 1 ? mode.dmDisplayFrequency : 0.0;
    }

    public static string QuoteArgument(string value)
    {
        if (value == null) return "\"\"";
        if (value.Length == 0) return "\"\"";
        if (value.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '\"' }) < 0) return value;

        var sb = new StringBuilder();
        sb.Append('\"');
        int slashCount = 0;
        foreach (char c in value)
        {
            if (c == '\\')
            {
                slashCount++;
                continue;
            }
            if (c == '\"')
            {
                sb.Append('\\', slashCount * 2 + 1);
                sb.Append('\"');
                slashCount = 0;
                continue;
            }
            if (slashCount > 0)
            {
                sb.Append('\\', slashCount);
                slashCount = 0;
            }
            sb.Append(c);
        }
        if (slashCount > 0) sb.Append('\\', slashCount * 2);
        sb.Append('\"');
        return sb.ToString();
    }

    public static string JoinArguments(string[] values)
    {
        var parts = new List<string>();
        foreach (string value in values) parts.Add(QuoteArgument(value));
        return string.Join(" ", parts.ToArray());
    }
}
'@
}

function Invoke-NativeCaptured {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [int]$TimeoutSeconds = 60
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    $psi.Arguments = [AdaptiveMediaHardwareNative]::JoinArguments($Arguments)

    $proc = [System.Diagnostics.Process]::Start($psi)
    if (-not $proc) { throw "Could not start: $FilePath" }
    try {
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill() } catch {}
            throw "Timed out after $TimeoutSeconds second(s): $FilePath"
        }
        $stdoutTask.Wait()
        $stderrTask.Wait()
        [pscustomobject]@{
            ExitCode = [int]$proc.ExitCode
            StdOut = [string]$stdoutTask.Result
            StdErr = [string]$stderrTask.Result
        }
    }
    finally {
        $proc.Dispose()
    }
}

function Start-InstrumentedMpv {
    param(
        [Parameter(Mandatory=$true)][string]$Executable,
        [Parameter(Mandatory=$true)][string[]]$PlanArguments,
        [Parameter(Mandatory=$true)][string]$PipePath
    )

    $instrumentation = @(
        '--input-ipc-server=' + $PipePath,
        '--terminal=no',
        '--mute=yes',
        '--loop-file=inf',
        '--title=Adaptive Media 0.3.2 Hardware Certification'
    )
    $arguments = @($instrumentation + $PlanArguments)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Executable
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $false
    $psi.Arguments = [AdaptiveMediaHardwareNative]::JoinArguments($arguments)
    $proc = [System.Diagnostics.Process]::Start($psi)
    if (-not $proc) { throw 'Could not start the planned mpv process.' }
    return $proc
}

function Resolve-ExecutablePath {
    param([Parameter(Mandatory=$true)][string]$Executable)
    if ([IO.Path]::IsPathRooted($Executable) -and (Test-Path -LiteralPath $Executable -PathType Leaf)) {
        return (Resolve-Path -LiteralPath $Executable).Path
    }
    $command = Get-Command $Executable -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    throw "Playback executable was not found: $Executable"
}

function Get-SelectedMediaPath {
    param([string]$Requested)
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        if (-not (Test-Path -LiteralPath $Requested -PathType Leaf)) { throw "Media file not found: $Requested" }
        return (Resolve-Path -LiteralPath $Requested).Path
    }

    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Choose one local video for Adaptive Media 0.3.2 hardware certification'
    $dialog.Filter = 'Video files|*.mkv;*.mp4;*.m4v;*.mov;*.webm;*.avi;*.ts;*.m2ts|All files|*.*'
    $dialog.Multiselect = $false
    try {
        if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
        return $dialog.FileName
    }
    finally {
        $dialog.Dispose()
    }
}

function Test-HasArgument {
    param([object]$Plan, [string]$Argument)
    return @($Plan.Arguments | Where-Object { [string]::Equals([string]$_, $Argument, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
}

function Add-Finding {
    param(
        [Parameter(Mandatory=$true)][System.Collections.ArrayList]$Target,
        [Parameter(Mandatory=$true)][string]$Message
    )
    [void]$Target.Add($Message)
}

function Read-LineWithTimeout {
    param(
        [Parameter(Mandatory=$true)][System.IO.StreamReader]$Reader,
        [int]$TimeoutMs = 5000
    )
    $task = $Reader.ReadLineAsync()
    if (-not $task.Wait($TimeoutMs)) { throw "Timed out waiting for mpv IPC response after $TimeoutMs ms." }
    return $task.Result
}

$script:IpcRequestId = 0
function Invoke-MpvIpc {
    param(
        [Parameter(Mandatory=$true)][System.IO.StreamReader]$Reader,
        [Parameter(Mandatory=$true)][System.IO.StreamWriter]$Writer,
        [Parameter(Mandatory=$true)][object[]]$Command,
        [int]$TimeoutMs = 5000
    )

    $script:IpcRequestId++
    $id = $script:IpcRequestId
    $request = @{ command = $Command; request_id = $id } | ConvertTo-Json -Compress -Depth 8
    $Writer.WriteLine($request)

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        $remaining = [Math]::Max(50, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        $line = Read-LineWithTimeout -Reader $Reader -TimeoutMs $remaining
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $response = $line | ConvertFrom-Json
        if ($null -ne $response.request_id -and [int]$response.request_id -eq $id) { return $response }
    }
    throw 'Timed out waiting for the matching mpv IPC request id.'
}

function Get-MpvProperty {
    param(
        [Parameter(Mandatory=$true)][System.IO.StreamReader]$Reader,
        [Parameter(Mandatory=$true)][System.IO.StreamWriter]$Writer,
        [Parameter(Mandatory=$true)][string]$Name
    )
    try {
        $response = Invoke-MpvIpc -Reader $Reader -Writer $Writer -Command @('get_property', $Name)
        if ([string]::Equals([string]$response.error, 'success', [StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ Available = $true; Value = $response.data; Error = $null; Name = $Name }
        }
        return [pscustomobject]@{ Available = $false; Value = $null; Error = [string]$response.error; Name = $Name }
    }
    catch {
        return [pscustomobject]@{ Available = $false; Value = $null; Error = $_.Exception.Message; Name = $Name }
    }
}

function Get-MpvPropertyWithAliases {
    param(
        [Parameter(Mandatory=$true)][System.IO.StreamReader]$Reader,
        [Parameter(Mandatory=$true)][System.IO.StreamWriter]$Writer,
        [Parameter(Mandatory=$true)][string[]]$Names
    )
    foreach ($name in $Names) {
        $value = Get-MpvProperty -Reader $Reader -Writer $Writer -Name $name
        if ($value.Available) { return $value }
    }
    return $value
}

function Set-MpvProperty {
    param(
        [Parameter(Mandatory=$true)][System.IO.StreamReader]$Reader,
        [Parameter(Mandatory=$true)][System.IO.StreamWriter]$Writer,
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)]$Value
    )
    $response = Invoke-MpvIpc -Reader $Reader -Writer $Writer -Command @('set_property', $Name, $Value)
    if (-not [string]::Equals([string]$response.error, 'success', [StringComparison]::OrdinalIgnoreCase)) {
        throw "mpv rejected set_property $Name: $($response.error)"
    }
}

function Send-MpvKeypress {
    param(
        [Parameter(Mandatory=$true)][System.IO.StreamReader]$Reader,
        [Parameter(Mandatory=$true)][System.IO.StreamWriter]$Writer,
        [Parameter(Mandatory=$true)][string]$Key
    )
    $response = Invoke-MpvIpc -Reader $Reader -Writer $Writer -Command @('keypress', $Key)
    if (-not [string]::Equals([string]$response.error, 'success', [StringComparison]::OrdinalIgnoreCase)) {
        throw "mpv rejected keypress $Key: $($response.error)"
    }
}

function Get-NumberOrNull {
    param($PropertyResult)
    if (-not $PropertyResult.Available -or $null -eq $PropertyResult.Value) { return $null }
    try { return [double]$PropertyResult.Value } catch { return $null }
}

function Wait-ForPropertyValue {
    param(
        [Parameter(Mandatory=$true)][System.IO.StreamReader]$Reader,
        [Parameter(Mandatory=$true)][System.IO.StreamWriter]$Writer,
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)]$Expected,
        [int]$TimeoutMs = 4000
    )
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        $value = Get-MpvProperty -Reader $Reader -Writer $Writer -Name $Name
        if ($value.Available -and $value.Value -eq $Expected) { return $true }
        Start-Sleep -Milliseconds 150
    }
    return $false
}

function Write-CertificationResult {
    param([Parameter(Mandatory=$true)]$Result)
    $dir = Join-Path $env:LOCALAPPDATA 'AdaptiveMedia\certification'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $path = Join-Path $dir '0.3.2-hardware.json'
    $Result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Invoke-SelfTest {
    Add-HardwareHelperType
    $temp = Join-Path $env:TEMP ('adaptive-media-hardware-selftest-' + [Guid]::NewGuid().ToString('N') + '.ps1')
    try {
        @'
param([string]$A,[string]$B,[string]$C)
[Console]::Out.Write((@($A,$B,$C) | ConvertTo-Json -Compress))
'@ | Set-Content -LiteralPath $temp -Encoding UTF8

        $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $expected = @('alpha beta', 'quote"inside', 'C:\path with spaces\')
        $probe = Invoke-NativeCaptured -FilePath $powershell -Arguments @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$temp,'-A',$expected[0],'-B',$expected[1],'-C',$expected[2]) -TimeoutSeconds 20
        if ($probe.ExitCode -ne 0) { throw "Argument-quoting self-test process failed: $($probe.StdErr)" }
        $actual = @($probe.StdOut | ConvertFrom-Json)
        if ($actual.Count -ne 3) { throw 'Argument-quoting self-test returned the wrong argument count.' }
        for ($i = 0; $i -lt 3; $i++) {
            if ([string]$actual[$i] -ne [string]$expected[$i]) { throw "Argument-quoting self-test mismatch at index $i." }
        }

        $quoted = [AdaptiveMediaHardwareNative]::QuoteArgument('ends with slash\')
        if ([string]::IsNullOrWhiteSpace($quoted)) { throw 'Native argument quote helper returned an empty value.' }
        $refresh = [AdaptiveMediaHardwareNative]::GetPrimaryRefreshHz()
        if ($refresh -lt 0 -or $refresh -gt 1000) { throw "Primary refresh helper returned an impossible value: $refresh" }
        Write-Host 'Adaptive Media 0.3.2 hardware certification gate self-test: PASS'
        return 0
    }
    finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

Add-HardwareHelperType
if ($SelfTest) { exit (Invoke-SelfTest) }

$failures = New-Object System.Collections.ArrayList
$unverified = New-Object System.Collections.ArrayList
$notes = New-Object System.Collections.ArrayList
$metrics = [ordered]@{}
$planSnapshot = $null
$mpvProcess = $null
$pipe = $null
$reader = $null
$writer = $null
$resultPath = $null

try {
    $app = Join-Path $InstallRoot 'AdaptiveMedia.exe'
    $engine = Join-Path $InstallRoot 'AdaptiveMedia.Engine.ps1'
    if (-not (Test-Path -LiteralPath $app -PathType Leaf)) { throw "Adaptive Media is not installed at: $InstallRoot" }
    if (-not (Test-Path -LiteralPath $engine -PathType Leaf)) { throw "Installed playback engine is missing: $engine" }

    $versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($app)
    $candidateVersion = [string]$versionInfo.ProductVersion
    if ([string]::IsNullOrWhiteSpace($candidateVersion)) { $candidateVersion = [string]$versionInfo.FileVersion }
    $metrics.CandidateVersion = $candidateVersion
    if ($candidateVersion -notmatch '^0\.3\.2(?:\b|-)') {
        throw "This gate only certifies an installed 0.3.2 candidate. Installed version is '$candidateVersion'."
    }

    $self = Invoke-NativeCaptured -FilePath $app -Arguments @('--self-test') -TimeoutSeconds 30
    if ($self.ExitCode -ne 0) { Add-Finding $failures "Installed AdaptiveMedia.exe --self-test failed with exit code $($self.ExitCode)." }
    else { Add-Finding $notes 'Installed native self-test: PASS' }

    $integration = Invoke-NativeCaptured -FilePath $app -Arguments @('--integration-test') -TimeoutSeconds 60
    if ($integration.ExitCode -ne 0) { Add-Finding $failures "Installed WPF/backend/engine integration test failed with exit code $($integration.ExitCode)." }
    else { Add-Finding $notes 'Installed WPF/backend/engine integration test: PASS' }

    if ($failures.Count -gt 0) { throw 'Installed candidate failed prerequisite certification checks.' }

    $media = Get-SelectedMediaPath -Requested $MediaPath
    if ([string]::IsNullOrWhiteSpace($media)) {
        Add-Finding $unverified 'No media file was selected; runtime hardware certification was not performed.'
        throw 'CERTIFICATION_CANCELLED'
    }
    $metrics.Media = $media

    $gpus = @()
    try { $gpus = @(Get-CimInstance Win32_VideoController | ForEach-Object { [string]$_.Name }) } catch {}
    $hasNvidia = @($gpus | Where-Object { $_ -match 'NVIDIA' }).Count -gt 0
    $metrics.Gpus = $gpus
    $metrics.NvidiaDetected = $hasNvidia

    $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $planCall = Invoke-NativeCaptured -FilePath $powershell -Arguments @(
        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$engine,
        '-Headless','-PlanJson','-PlaybackProfile','Enhanced','-UpscaleMode','Off','-MotionMode','Smooth',$media
    ) -TimeoutSeconds 60
    if ($planCall.ExitCode -ne 0) { throw "Installed engine could not produce the Smooth launch plan: $($planCall.StdErr)" }
    try { $planSnapshot = $planCall.StdOut.Trim() | ConvertFrom-Json } catch { throw "Installed engine returned invalid launch-plan JSON: $($planCall.StdOut)" }
    if ($null -eq $planSnapshot -or $null -eq $planSnapshot.Arguments) { throw 'Installed engine returned an incomplete launch plan.' }

    foreach ($required in @('--video-sync=display-resample','--video-sync-max-factor=10','--interpolation=yes','--tscale=linear')) {
        if (-not (Test-HasArgument $planSnapshot $required)) { Add-Finding $failures "Smooth launch plan is missing required argument: $required" }
    }
    if (Test-HasArgument $planSnapshot '--video-sync-max-factor=12') { Add-Finding $failures 'Smooth launch plan still contains invalid video-sync-max-factor=12.' }

    if ($hasNvidia) {
        if (-not (Test-HasArgument $planSnapshot '--profile=nvidia')) { Add-Finding $failures 'NVIDIA hardware is present but the launch plan did not select the managed NVIDIA profile.' }
        if (-not (Test-HasArgument $planSnapshot '--vulkan-swap-mode=fifo')) { Add-Finding $failures 'NVIDIA Smooth plan did not request Vulkan FIFO presentation.' }
        if (Test-HasArgument $planSnapshot '--gpu-api=d3d11' -or Test-HasArgument $planSnapshot '--gpu-context=d3d11') { Add-Finding $failures 'NVIDIA Smooth plan unexpectedly contains an explicit D3D11 renderer override.' }
    }

    if ($failures.Count -gt 0) { throw 'Launch-plan certification failed before playback.' }

    $mpvExe = Resolve-ExecutablePath ([string]$planSnapshot.Executable)
    $pipeName = 'AdaptiveMediaCert-' + [Guid]::NewGuid().ToString('N')
    $pipePath = '\\.\pipe\' + $pipeName
    $mpvProcess = Start-InstrumentedMpv -Executable $mpvExe -PlanArguments @($planSnapshot.Arguments | ForEach-Object { [string]$_ }) -PipePath $pipePath

    $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::None)
    try { $pipe.Connect(12000) } catch { throw "Could not connect to mpv JSON IPC. $($_.Exception.Message)" }
    $reader = New-Object System.IO.StreamReader($pipe, (New-Object System.Text.UTF8Encoding($false)), $false, 4096, $true)
    $writer = New-Object System.IO.StreamWriter($pipe, (New-Object System.Text.UTF8Encoding($false)), 4096, $true)
    $writer.AutoFlush = $true

    $readyDeadline = [DateTime]::UtcNow.AddSeconds(12)
    $videoCodec = $null
    while ([DateTime]::UtcNow -lt $readyDeadline) {
        if ($mpvProcess.HasExited) { throw "mpv exited during startup with code $($mpvProcess.ExitCode)." }
        $codecProbe = Get-MpvProperty -Reader $reader -Writer $writer -Name 'video-codec'
        if ($codecProbe.Available -and -not [string]::IsNullOrWhiteSpace([string]$codecProbe.Value)) {
            $videoCodec = [string]$codecProbe.Value
            break
        }
        Start-Sleep -Milliseconds 250
    }
    if ([string]::IsNullOrWhiteSpace($videoCodec)) { throw 'mpv did not expose an active video codec within the startup window.' }
    $metrics.VideoCodec = $videoCodec

    Write-Host "Hardware gate: warming up for $WarmupSeconds second(s) so hybrid-GPU/display transitions settle..."
    Start-Sleep -Seconds $WarmupSeconds
    if ($mpvProcess.HasExited) { throw "mpv exited during warmup with code $($mpvProcess.ExitCode)." }

    $displaySync = Get-MpvProperty -Reader $reader -Writer $writer -Name 'display-sync-active'
    $displayFps = Get-MpvPropertyWithAliases -Reader $reader -Writer $writer -Names @('display-fps','display_fps')
    $gpuApi = Get-MpvProperty -Reader $reader -Writer $writer -Name 'options/gpu-api'
    $gpuContext = Get-MpvProperty -Reader $reader -Writer $writer -Name 'options/gpu-context'
    $swapMode = Get-MpvProperty -Reader $reader -Writer $writer -Name 'options/vulkan-swap-mode'
    $hwdecOption = Get-MpvProperty -Reader $reader -Writer $writer -Name 'options/hwdec'
    $hwdecCurrent = Get-MpvProperty -Reader $reader -Writer $writer -Name 'hwdec-current'
    $avsync = Get-MpvProperty -Reader $reader -Writer $writer -Name 'avsync'

    $metrics.DisplaySyncActive = if ($displaySync.Available) { $displaySync.Value } else { $null }
    $metrics.MpvDisplayFps = Get-NumberOrNull $displayFps
    $metrics.GpuApi = if ($gpuApi.Available) { $gpuApi.Value } else { $null }
    $metrics.GpuContext = if ($gpuContext.Available) { $gpuContext.Value } else { $null }
    $metrics.VulkanSwapMode = if ($swapMode.Available) { $swapMode.Value } else { $null }
    $metrics.HwdecOption = if ($hwdecOption.Available) { $hwdecOption.Value } else { $null }
    $metrics.HwdecCurrent = if ($hwdecCurrent.Available) { $hwdecCurrent.Value } else { $null }
    $metrics.AvSync = Get-NumberOrNull $avsync

    if (-not $displaySync.Available) { Add-Finding $unverified "mpv did not expose display-sync-active: $($displaySync.Error)" }
    elseif (-not [bool]$displaySync.Value) { Add-Finding $failures 'mpv reports display-sync-active=false during the Smooth run.' }

    $mpvRefresh = Get-NumberOrNull $displayFps
    if ($null -eq $mpvRefresh -or $mpvRefresh -le 0) {
        Add-Finding $failures 'mpv did not report a positive display refresh rate.'
    }

    $windowsRefresh = if ($ExpectedRefreshHz -gt 0) { $ExpectedRefreshHz } else { [AdaptiveMediaHardwareNative]::GetPrimaryRefreshHz() }
    $metrics.WindowsRefreshHz = $windowsRefresh
    if ($windowsRefresh -le 0) {
        Add-Finding $unverified 'Windows current primary-display refresh could not be read; refresh matching is unverified.'
    }
    elseif ($null -ne $mpvRefresh -and $mpvRefresh -gt 0) {
        $refreshTolerance = [Math]::Max(1.5, $windowsRefresh * 0.01)
        $metrics.RefreshToleranceHz = $refreshTolerance
        $metrics.RefreshDeltaHz = [Math]::Abs($mpvRefresh - $windowsRefresh)
        if ([Math]::Abs($mpvRefresh - $windowsRefresh) -gt $refreshTolerance) {
            Add-Finding $failures ("mpv display refresh ({0:N3} Hz) does not match Windows ({1:N3} Hz) within {2:N3} Hz." -f $mpvRefresh,$windowsRefresh,$refreshTolerance)
        }
    }

    if ($hasNvidia) {
        if (-not $gpuApi.Available) { Add-Finding $unverified 'Effective gpu-api was not available through mpv IPC.' }
        elseif ([string]$gpuApi.Value -notmatch '^vulkan$') { Add-Finding $failures "Effective NVIDIA gpu-api is '$($gpuApi.Value)', expected Vulkan." }
        if (-not $gpuContext.Available) { Add-Finding $unverified 'Effective gpu-context was not available through mpv IPC.' }
        elseif ([string]$gpuContext.Value -notmatch '^winvk$') { Add-Finding $failures "Effective NVIDIA gpu-context is '$($gpuContext.Value)', expected winvk." }
        if (-not $swapMode.Available) { Add-Finding $unverified 'Effective Vulkan swap mode was not available through mpv IPC.' }
        elseif ([string]$swapMode.Value -notmatch '^fifo$') { Add-Finding $failures "Effective Vulkan swap mode is '$($swapMode.Value)', expected fifo." }

        if ($videoCodec -match '(?i)h264|avc|hevc|h265|vp9|av1') {
            if (-not $hwdecCurrent.Available -or [string]::IsNullOrWhiteSpace([string]$hwdecCurrent.Value)) {
                Add-Finding $unverified 'Hardware decoder state was unavailable for a codec normally supported by NVDEC.'
            }
            elseif ([string]$hwdecCurrent.Value -notmatch '(?i)nvdec') {
                Add-Finding $failures "Expected NVDEC hardware decode for '$videoCodec', but mpv reports '$($hwdecCurrent.Value)'."
            }
        } else {
            Add-Finding $unverified "Codec '$videoCodec' is outside this gate's NVDEC expectation list; hardware-decode certification is not asserted."
        }
    }

    $baseFrame = Get-MpvProperty -Reader $reader -Writer $writer -Name 'frame-drop-count'
    $baseDecoder = Get-MpvProperty -Reader $reader -Writer $writer -Name 'decoder-frame-drop-count'
    $baseDelayed = Get-MpvProperty -Reader $reader -Writer $writer -Name 'vo-delayed-frame-count'

    Write-Host "Hardware gate: measuring steady-state playback for $MeasureSeconds second(s)..."
    Start-Sleep -Seconds $MeasureSeconds
    if ($mpvProcess.HasExited) { throw "mpv exited during steady-state measurement with code $($mpvProcess.ExitCode)." }

    $endFrame = Get-MpvProperty -Reader $reader -Writer $writer -Name 'frame-drop-count'
    $endDecoder = Get-MpvProperty -Reader $reader -Writer $writer -Name 'decoder-frame-drop-count'
    $endDelayed = Get-MpvProperty -Reader $reader -Writer $writer -Name 'vo-delayed-frame-count'

    $counterSpecs = @(
        @{ Name='FrameDropDelta'; Label='output frame drops'; Start=$baseFrame; End=$endFrame; Limit=1 },
        @{ Name='DecoderDropDelta'; Label='decoder frame drops'; Start=$baseDecoder; End=$endDecoder; Limit=0 },
        @{ Name='DelayedFrameDelta'; Label='delayed video frames'; Start=$baseDelayed; End=$endDelayed; Limit=3 }
    )
    foreach ($spec in $counterSpecs) {
        $startValue = Get-NumberOrNull $spec.Start
        $endValue = Get-NumberOrNull $spec.End
        if ($null -eq $startValue -or $null -eq $endValue) {
            $metrics[$spec.Name] = $null
            Add-Finding $unverified "mpv did not expose enough data to measure $($spec.Label)."
            continue
        }
        $delta = [Math]::Max(0, $endValue - $startValue)
        $metrics[$spec.Name] = $delta
        if ($delta -gt [double]$spec.Limit) {
            Add-Finding $failures "$($spec.Label) increased by $delta during the steady-state window (limit $($spec.Limit))."
        }
    }

    Set-MpvProperty -Reader $reader -Writer $writer -Name 'fullscreen' -Value $true
    if (-not (Wait-ForPropertyValue -Reader $reader -Writer $writer -Name 'fullscreen' -Expected $true -TimeoutMs 4000)) {
        Add-Finding $failures 'mpv did not enter fullscreen for the ESC behaviour check.'
    } else {
        Send-MpvKeypress -Reader $reader -Writer $writer -Key 'ESC'
        $leftFullscreen = Wait-ForPropertyValue -Reader $reader -Writer $writer -Name 'fullscreen' -Expected $false -TimeoutMs 4000
        if (-not $leftFullscreen) { Add-Finding $failures 'ESC did not leave fullscreen.' }
        elseif ($mpvProcess.HasExited) { Add-Finding $failures 'ESC left fullscreen but also terminated playback.' }
        else { Add-Finding $notes 'ESC fullscreen behaviour: PASS (left fullscreen, playback remained alive)' }
    }

    $status = if ($failures.Count -gt 0) { 'FAIL' } elseif ($unverified.Count -gt 0) { 'UNVERIFIED' } else { 'PASS' }
    $result = [ordered]@{
        Schema = 'adaptive-media-hardware-certification/v1'
        Candidate = $candidateVersion
        Status = $status
        TimestampUtc = [DateTime]::UtcNow.ToString('o')
        WarmupSeconds = $WarmupSeconds
        MeasureSeconds = $MeasureSeconds
        Metrics = $metrics
        Failures = @($failures)
        Unverified = @($unverified)
        Notes = @($notes)
        LaunchPlan = $planSnapshot
    }
    $resultPath = Write-CertificationResult $result

    Write-Host ''
    Write-Host "Adaptive Media 0.3.2 hardware certification: $status"
    Write-Host "Result: $resultPath"
    foreach ($failure in $failures) { Write-Host "FAIL: $failure" }
    foreach ($item in $unverified) { Write-Host "UNVERIFIED: $item" }
    foreach ($note in $notes) { Write-Host "NOTE: $note" }

    if ($status -eq 'PASS') { exit 0 }
    if ($status -eq 'UNVERIFIED') { exit 3 }
    exit 2
}
catch {
    if ($_.Exception.Message -eq 'CERTIFICATION_CANCELLED') {
        $status = 'UNVERIFIED'
    } else {
        if ($failures.Count -eq 0 -or -not (@($failures) -contains $_.Exception.Message)) {
            Add-Finding $failures $_.Exception.Message
        }
        $status = 'FAIL'
    }

    $result = [ordered]@{
        Schema = 'adaptive-media-hardware-certification/v1'
        Candidate = $metrics.CandidateVersion
        Status = $status
        TimestampUtc = [DateTime]::UtcNow.ToString('o')
        WarmupSeconds = $WarmupSeconds
        MeasureSeconds = $MeasureSeconds
        Metrics = $metrics
        Failures = @($failures)
        Unverified = @($unverified)
        Notes = @($notes)
        LaunchPlan = $planSnapshot
    }
    try { $resultPath = Write-CertificationResult $result } catch {}

    Write-Host ''
    Write-Host "Adaptive Media 0.3.2 hardware certification: $status"
    if ($resultPath) { Write-Host "Result: $resultPath" }
    foreach ($failure in $failures) { Write-Host "FAIL: $failure" }
    foreach ($item in $unverified) { Write-Host "UNVERIFIED: $item" }

    if ($status -eq 'UNVERIFIED') { exit 3 }
    exit 2
}
finally {
    if ($writer) { try { $writer.Dispose() } catch {} }
    if ($reader) { try { $reader.Dispose() } catch {} }
    if ($pipe) { try { $pipe.Dispose() } catch {} }
    if ($mpvProcess) {
        try {
            if (-not $mpvProcess.HasExited) {
                try {
                    # IPC streams may already be disposed on an error; fall back to a bounded kill.
                    $mpvProcess.CloseMainWindow() | Out-Null
                    if (-not $mpvProcess.WaitForExit(2000)) { $mpvProcess.Kill() }
                } catch { try { $mpvProcess.Kill() } catch {} }
            }
        } finally { $mpvProcess.Dispose() }
    }
}
