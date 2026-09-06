#requires -Version 5.1
# Compatibility entry point. All playback planning and launching lives in the compiled app.
param([Parameter(Position=0,ValueFromRemainingArguments=$true)][string[]]$LaunchItems,
 [switch]$Headless,[switch]$PlanJson,[switch]$SystemJson,[switch]$Diagnostics,
 [string]$PlaybackProfile='Automatic',[string]$UpscaleMode='Off',[string]$MotionMode='Off',
 [switch]$Cleanup,[switch]$RtxHdr,[string]$YtdlFormat)
$ErrorActionPreference='Stop'
if($SystemJson) {
 Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class InventoryDpi { [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value); }'
 [void][InventoryDpi]::SetProcessDpiAwarenessContext([IntPtr](-4))
 Add-Type -AssemblyName System.Windows.Forms
 $gpus=@(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
 $nvidia=$gpus | Where-Object Name -Match 'NVIDIA' | Select-Object -First 1
 $mpv=Get-Command mpv.exe -ErrorAction SilentlyContinue
 $mpvPath=if($mpv){$mpv.Source}elseif(Test-Path -LiteralPath 'C:\mpv\mpv.exe'){'C:\mpv\mpv.exe'}else{''}
 $screens=@([Windows.Forms.Screen]::AllScreens | ForEach-Object { [pscustomobject]@{Name=$_.DeviceName;Width=$_.Bounds.Width;Height=$_.Bounds.Height;WorkWidth=$_.WorkingArea.Width;WorkHeight=$_.WorkingArea.Height;Primary=$_.Primary} })
 [pscustomobject]@{ Gpu=($gpus.Name -join ' + '); HasNvidia=($null -ne $nvidia); NvidiaAdapter=if($nvidia){$nvidia.Name}else{$null}; Drivers=@($gpus | ForEach-Object { $_.Name + ': ' + $_.DriverVersion }); Cpu=((Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue).Name -join '; '); Screens=$screens; Displays=(($screens | ForEach-Object { '{0}x{1}' -f $_.Width,$_.Height }) -join '; '); Audio=((Get-CimInstance Win32_SoundDevice -ErrorAction SilentlyContinue).Name -join '; '); Power=[Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus.ToString(); MpvPath=$mpvPath; MpvAvailable=([bool]$mpvPath); YtDlpAvailable=([bool](Get-Command yt-dlp.exe -ErrorAction SilentlyContinue)); HdrInteropAvailable=$true } | ConvertTo-Json -Depth 5 -Compress
 exit 0
}
$psi=New-Object Diagnostics.ProcessStartInfo
$psi.FileName=Join-Path $PSScriptRoot 'AdaptiveMedia.exe'
$psi.UseShellExecute=$false
$psi.CreateNoWindow=$true
$psi.RedirectStandardInput=$true
$psi.RedirectStandardOutput=$true
$psi.RedirectStandardError=$true
$psi.Arguments=if($Diagnostics){'--diagnostics'}elseif($PlanJson){'--plan-stdin'}else{'--play-stdin'}
$p=[Diagnostics.Process]::Start($psi)
$out=$p.StandardOutput.ReadToEndAsync(); $err=$p.StandardError.ReadToEndAsync()
if(-not $Diagnostics){
 $request=@{Items=@($LaunchItems);Options=@{Profile=$PlaybackProfile;UpscaleMode=$UpscaleMode;MotionMode=$MotionMode;Cleanup=[bool]$Cleanup;RtxHdr=[bool]$RtxHdr;YtdlFormat=$YtdlFormat}}
 # ProcessStartInfo.StandardInputEncoding does not exist on .NET Framework, so
 # Windows PowerShell 5.1 cannot set it. Write UTF-8 bytes to the raw stream
 # instead; both PowerShell runtimes then send byte-identical requests.
 $utf8=New-Object Text.UTF8Encoding($false)
 $payload=$utf8.GetBytes((($request | ConvertTo-Json -Depth 5 -Compress) + "`n"))
 $p.StandardInput.BaseStream.Write($payload,0,$payload.Length)
 $p.StandardInput.BaseStream.Flush()
}
$p.StandardInput.Close(); $p.WaitForExit()
if($p.ExitCode -ne 0){[Console]::Error.WriteLine($err.Result)}
[Console]::Out.Write($out.Result)
exit $p.ExitCode

