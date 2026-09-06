# Adaptive Media 0.4.0-rc1

Release candidate. Installed side by side with 0.3.2 under its own AppId and its
own settings directory (`%LOCALAPPDATA%\AdaptiveMediaPreview`); it does not
replace, upgrade or modify an existing 0.3.2 install.

## The 0.3.2 defect this candidate fixes

The 0.3.2 engine probed media with `--really-quiet`, which suppressed the probe
marker. `Probe-Media` therefore returned no dimensions and per-video RTX VPP was
never constructed, so requesting RTX Video Super Resolution silently produced
conventional playback. The 0.3.2 integration test injected a synthetic probe
result and never exercised that path, so it stayed green.

`tests/Test-RealProbe.ps1` now reproduces the original failure against real media
on every installed PowerShell runtime.

## What changed

- Playback planning is typed, pure and inspectable. One builder turns a request,
  a real media probe, display geometry and hardware capabilities into an
  immutable plan; the plan's argument vector is what actually launches, verified
  at runtime by comparing a SHA-256 fingerprint of the real process argv.
- Media is probed for real (dimensions, transfer, primaries, pixel format,
  aspect, audio codec) and the plan scales to fit the source in the destination.
- RTX Video Super Resolution and RTX Video HDR use the D3D11/D3D11VA/VPP lane.
  The bundled runtime script follows window, fullscreen, monitor and playlist
  changes, disables the filter when output becomes smaller than the source, and
  re-enables it when it becomes useful again.
- Non-RTX NVIDIA hardware keeps the Vulkan/winvk/NVDEC reference lane.
  Compatibility remains an independent D3D11 path on NVIDIA hardware.
- Automatic Windows HDR switching is limited to a single unambiguous compatible
  HDMI display and a single item. Playlists preserve the current display state,
  because later items are not inspected before playback. HDR is restored when
  playback ends, when the launcher is closed during playback, and on process
  shutdown; a recovery file restores it on the next launch otherwise.
- Unknown colour metadata is never treated as SDR, so RTX HDR is not applied to
  it, and automatic banding reduction stays off for it.
- Live IPC observation reports requested versus constructed versus observed
  state, retries once conservatively after an RTX failure with explicit history,
  and saves redacted diagnostics on shutdown.
- Settings are versioned, validated and saved atomically. Unknown and
  newer-schema files are preserved rather than overwritten.
- Setup refreshes an already-installed yt-dlp instead of leaving a stale build
  in place, and the plan says so when yt-dlp is missing for a site URL.

## Validation

Run from `adaptive-media`:

```powershell
dotnet run --project source/tests -c Release
dotnet run --project source/tests -c Release -- 'C:\mpv\mpv.exe' <1080p file>
dotnet run --project tests/SettingsTests -c Release
pwsh -File tests/Test-Packaging.ps1
pwsh -File tests/Test-Reconstruction.ps1
pwsh -File tests/Test-RealProbe.ps1 -Engine <installed AdaptiveMedia.Engine.ps1> -MediaPath <1080p file>
pwsh -File source/scripts/Build-Dev.ps1 -Clean -SmokeTest
pwsh -File tests/Test-PlaybackHardware.ps1 -App <AdaptiveMedia.exe> -Media <1080p file> -Resize -CloseLauncherDuringPlayback
```

The hardware harness needs a real GPU and opens a real player window.

## Not yet verified

- Automatic Windows HDR switching and restoration on a real HDR HDMI display.
- HDMI bitstream / Atmos passthrough on a real endpoint.
- Live network dependency provisioning (MPV, yt-dlp, MPC-BE) on a clean machine.
- Behaviour on non-NVIDIA and on multi-GPU desktop topologies.
- URL playback end to end, which depends on a current yt-dlp.
