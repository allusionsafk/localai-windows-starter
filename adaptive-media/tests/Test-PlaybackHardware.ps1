#requires -Version 7.0
param([Parameter(Mandatory=$true)][string]$App,[Parameter(Mandatory=$true)][string]$Media,
 [string]$OutputRoot=(Join-Path $PSScriptRoot '..\.artifacts\hardware'),
 [ValidateSet('RtxVsr','Off','HighQuality')][string]$Upscale='RtxVsr',
 [ValidateSet('Enhanced','Reference','Compatibility')][string]$Profile='Enhanced',
 [ValidateSet('Off','Gentle','Smooth')][string]$Motion='Smooth', [switch]$Resize, [switch]$CloseLauncherDuringPlayback)
$ErrorActionPreference='Stop'
if (-not ('WindowsArgv' -as [type])) {
 Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class WindowsArgv {
 [DllImport("shell32.dll",SetLastError=true)] static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)]string line,out int count);
 [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr pointer);
 public static string[] Parse(string line) { int count; var p=CommandLineToArgvW(line,out count); if(p==IntPtr.Zero)throw new Exception("Command line parse failed");try {var result=new string[count]; for(int i=0;i<count;i++)result[i]=Marshal.PtrToStringUni(Marshal.ReadIntPtr(p,i*IntPtr.Size));return result;} finally {LocalFree(p);} }
}
'@
}
$appPath=(Resolve-Path -LiteralPath $App).Path
$mediaPath=(Resolve-Path -LiteralPath $Media).Path
$run=Join-Path ([IO.Path]::GetFullPath($OutputRoot)) ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run -Force | Out-Null
@{SchemaVersion=1;Profile=$Profile;DefaultUpscaleMode=$Upscale;DefaultMotionMode=$Motion;DefaultCleanup=$true;AutoHdrSwitch=$false}|ConvertTo-Json|Set-Content (Join-Path $run settings.json)
$gui=$null;$player=$null;$pipe=$null
try {
 $psi=[Diagnostics.ProcessStartInfo]::new($appPath)
 $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
 $psi.Environment['ADAPTIVE_MEDIA_DATA_DIR']=$run
 $psi.ArgumentList.Add($mediaPath)
 $watch=[Diagnostics.Stopwatch]::StartNew()
 $gui=[Diagnostics.Process]::Start($psi)
 do {
  Start-Sleep -Milliseconds 250
  if($gui.HasExited){throw "GUI exited before playback ($($gui.ExitCode))"}
  $player=Get-CimInstance Win32_Process -Filter "Name='mpv.exe' AND ParentProcessId=$($gui.Id)" | Where-Object CommandLine -Match 'input-ipc-server' | Select-Object -First 1
 } while(-not $player -and $watch.Elapsed.TotalSeconds -lt 30)
 if(-not $player){throw 'GUI did not launch a player within 30 seconds'}
 $launchSeconds=$watch.Elapsed.TotalSeconds
 $pipeName=[regex]::Match($player.CommandLine,'adaptive-media-[0-9a-f]{32}').Value
 $pipe=[IO.Pipes.NamedPipeClientStream]::new('.',$pipeName,[IO.Pipes.PipeDirection]::InOut,[IO.Pipes.PipeOptions]::Asynchronous)
 $pipe.Connect(5000)
 $reader=[IO.StreamReader]::new($pipe)
 $writer=[IO.StreamWriter]::new($pipe,[Text.UTF8Encoding]::new($false));$writer.AutoFlush=$true
 function Ipc([object[]]$Command) {
  $writer.WriteLine((@{command=$Command;request_id=101}|ConvertTo-Json -Compress))
  do { $read=$reader.ReadLineAsync(); if(-not $read.Wait(5000)){throw 'IPC response timed out'}; if(-not $read.Result){throw 'IPC closed'}; $reply=$read.Result|ConvertFrom-Json } while($reply.request_id -ne 101)
  if($reply.error -ne 'success'){return $null};return $reply.data
 }
 function Snapshot {
  $result=[ordered]@{}
  foreach($property in @('gpu-api','gpu-context','hwdec-current','vf','video-params','video-out-params','osd-dimensions','display-fps','estimated-display-fps','video-sync','interpolation','vsync-jitter','frame-drop-count','decoder-frame-drop-count','vo-delayed-frame-count','current-ao','audio-out-params','user-data/adaptive/state')) {$result[$property]=Ipc @('get_property',$property)}
  return $result
 }
 Start-Sleep -Seconds 8
 $initial=Snapshot
 if($CloseLauncherDuringPlayback){
  [void]$gui.CloseMainWindow();Start-Sleep -Seconds 1
  if($gui.HasExited){throw 'Closing launcher abandoned active playback'}
 }
 $full=$null;$small=$null;$restored=$null
 if($Resize){
  Ipc @('set_property','fullscreen',$true)|Out-Null;Start-Sleep -Seconds 2;$full=Snapshot
  Ipc @('set_property','fullscreen',$false)|Out-Null;Ipc @('set_property','window-scale',0.5)|Out-Null;Start-Sleep -Seconds 2;$small=Snapshot
  Ipc @('set_property','fullscreen',$true)|Out-Null;Start-Sleep -Seconds 2;$restored=Snapshot
 }
 Ipc @('quit')|Out-Null
 $pipe.Dispose();$pipe=$null
 $latest=Join-Path $run 'diagnostics\latest.json'
 $wait=[Diagnostics.Stopwatch]::StartNew()
 while(-not (Test-Path -LiteralPath $latest) -and $wait.Elapsed.TotalSeconds -lt 10){Start-Sleep -Milliseconds 200}
 $result=[ordered]@{AppSha256=(Get-FileHash -LiteralPath $appPath).Hash;GuiPid=$gui.Id;MpvPid=$player.ProcessId;LaunchSeconds=$launchSeconds;CommandLine=$player.CommandLine;Initial=$initial;Fullscreen=$full;SmallWindow=$small;Restored=$restored;SessionDiagnosticsSaved=(Test-Path -LiteralPath $latest)}
 $result | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $run hardware.json)
 if(-not $result.SessionDiagnosticsSaved){throw 'GUI session did not save final diagnostics'}
 $diag=Get-Content -LiteralPath $latest -Raw | ConvertFrom-Json
 $actualArgs=@([WindowsArgv]::Parse($player.CommandLine) | Select-Object -Skip 1)
 $actualHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($actualArgs -join [char]0))))
 if($actualHash -ne $diag.Plan.ArgumentVectorSha256){throw 'Actual mpv argv differs from the canonical plan fingerprint'}
 if($diag.ExitCode -ne 0){throw "Playback failed with code $($diag.ExitCode)"}
 if($CloseLauncherDuringPlayback -and -not $gui.WaitForExit(5000)){throw 'Launcher did not exit after monitored playback completed'}
 if($Upscale -eq 'RtxVsr' -and $Profile -ne 'Compatibility') {
  if($initial.'hwdec-current' -ne 'd3d11va'){throw 'RTX did not use D3D11VA'}
  if(-not @($initial.vf | Where-Object name -eq 'd3d11vpp').Count){throw 'RTX filter is missing at runtime'}
  if($Resize -and @($small.vf | Where-Object name -eq 'd3d11vpp').Count){throw 'RTX filter remained when downscaling'}
  if($Resize -and -not @($restored.vf | Where-Object name -eq 'd3d11vpp').Count){throw 'RTX filter did not return after fullscreen'}
 }
 Write-Output "PASS: GUI startup -> canonical plan -> actual mpv IPC. Report: $run\hardware.json"
} finally {
 if($pipe){$pipe.Dispose()}
 if($player){$owned=Get-Process -Id $player.ProcessId -ErrorAction SilentlyContinue;if($owned -and $owned.Path -eq 'C:\mpv\mpv.exe'){Stop-Process -Id $owned.Id -ErrorAction SilentlyContinue}}
 if($gui -and -not $gui.HasExited){[void]$gui.CloseMainWindow();if(-not $gui.WaitForExit(3000)){$gui.Kill()}}
}
