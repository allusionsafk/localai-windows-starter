#requires -Version 7.0
param([string]$OutputRoot=(Join-Path $PSScriptRoot '..\.artifacts\fixtures'))
$ErrorActionPreference='Stop'
$OutputRoot=[IO.Path]::GetFullPath($OutputRoot)
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$cases=@(
 @{Name='h264-8';Encoder='libx264';Extra=@('-preset','ultrafast');Pixel='yuv420p'},
 @{Name='hevc-10';Encoder='libx265';Extra=@('-preset','ultrafast','-x265-params','pools=2:frame-threads=2:log-level=error');Pixel='yuv420p10le'},
 @{Name='av1-8';Encoder='libaom-av1';Extra=@('-cpu-used','8','-row-mt','1');Pixel='yuv420p'},
 @{Name='vp9-10';Encoder='libvpx-vp9';Extra=@('-deadline','realtime','-cpu-used','8');Pixel='yuv420p10le'},
 @{Name='mpeg4-software';Encoder='mpeg4';Extra=@();Pixel='yuv420p'}
)
foreach($case in $cases){
 $path=Join-Path $OutputRoot ($case.Name+'.mkv')
 & ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=640x360:rate=24' -f lavfi -i 'sine=frequency=440:sample_rate=48000' -t 1 -c:v $case.Encoder -threads 2 @($case.Extra) -pix_fmt $case.Pixel -c:a aac -y $path
 if($LASTEXITCODE -ne 0){throw "Fixture encoding failed: $($case.Name)"}
}
$odd=Join-Path $OutputRoot "spaces 日本語's (cut) [1].mkv"
Copy-Item -LiteralPath (Join-Path $OutputRoot 'h264-8.mkv') -Destination $odd -Force
$long=Join-Path $OutputRoot (('long-name-'*14)+'.mkv')
Copy-Item -LiteralPath (Join-Path $OutputRoot 'h264-8.mkv') -Destination $long -Force
Get-ChildItem -LiteralPath $OutputRoot -Filter '*.mkv' | Select-Object Name,Length
