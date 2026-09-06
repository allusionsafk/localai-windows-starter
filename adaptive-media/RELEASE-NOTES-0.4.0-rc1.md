# Adaptive Media 0.4.0-rc1

**Prerelease. Not promoted to stable.** This build exists for one independent
machine test. 0.3.2 remains the current release.

It installs **side by side** with 0.3.2: its own AppId, its own install
directory (`%LOCALAPPDATA%\Programs\Adaptive Media Preview`) and its own
settings directory (`%LOCALAPPDATA%\AdaptiveMediaPreview`). It does not read,
move, upgrade or remove an existing 0.3.2 install. If you dislike it, uninstall
it from Apps & features and 0.3.2 is untouched.

## Verify what you downloaded

`AdaptiveMediaSetup-0.4.0-rc1-x64.exe`

```
0A275527A0694FBF65B9568F53956C3035FE6C0CF0D2EC4B47AB32FABFC73634
```

```powershell
Get-FileHash .\AdaptiveMediaSetup-0.4.0-rc1-x64.exe -Algorithm SHA256
```

That must match exactly. `AdaptiveMediaSetup-0.4.0-rc1-x64.sha256.txt` carries
the same digest. These are the exact bytes that were tested; nothing was rebuilt
between validation and publication.

The installer is unsigned, so SmartScreen will warn. That is expected for a
prerelease going to one person.

## Installing

Run the installer. On the components page:

- **Install or repair MPV** — required unless you already have mpv.
- **Install yt-dlp** — only needed for URL playback. If you already have yt-dlp,
  this now upgrades it; a stale yt-dlp is the usual reason URLs stop working.
- **MPC-BE** — optional fallback.

Then pick a file, look at the plan it shows you, and press Play.

## What to look at, and what to send back

The plan text above the Play button states what it will actually do and, when it
declines something you asked for, why. If that text ever disagrees with what you
see on screen, that is the bug worth reporting.

Worth trying: a normal file; a 1080p file on a larger display with **RTX Video
Super Resolution** on; fullscreen and windowed, and resizing during playback;
**Smooth motion**; a folder as a playlist; the **Compatibility** profile.

To report anything, press **Copy diagnostics** in the app, or open
**Diagnostics** and send `latest.json`. Media paths, URLs and your user folder
are stripped from it before it is written.

## The 0.3.2 defect this fixes

0.3.2 probed media with `--really-quiet`, which suppressed the probe output. The
probe therefore returned no dimensions, and per-video RTX processing was never
constructed — so asking for RTX Video Super Resolution silently gave you
conventional playback instead. The old integration test injected a fake probe
result and never exercised that path, so it stayed green while the product was
broken.

## What else changed

- Playback planning is typed and inspectable. One builder turns your request, a
  real media probe, display geometry and detected hardware into an immutable
  plan, and that exact plan is what launches — verified at runtime by comparing
  a fingerprint of the real player's arguments against the plan.
- The player scales to fit the source in the destination, and does not upscale
  when upscaling is unnecessary.
- RTX processing follows window, fullscreen, monitor and playlist changes during
  playback: it turns off when the output becomes smaller than the source and
  back on when it becomes useful again.
- Non-RTX NVIDIA hardware keeps the Vulkan/winvk/NVDEC reference lane.
  Compatibility stays an independent D3D11 path on NVIDIA hardware.
- Automatic Windows HDR switching is limited to a single unambiguous compatible
  HDMI display and a single item. Playlists preserve your current display state,
  because later items are not inspected before playback. HDR is restored when
  playback ends, when you close the launcher during playback, and on shutdown; a
  recovery file restores it on the next launch if all of those are missed.
- Unknown colour metadata is never assumed to be SDR, so RTX HDR is not applied
  to it and automatic banding reduction stays off for it.
- An explicit high-quality scaling request is now honoured on the RTX path when
  RTX super resolution itself is not in use. It used to be dropped there while
  the plan still claimed it.
- The compatibility entry point (`AdaptiveMedia.Engine.ps1`) failed on Windows
  PowerShell 5.1, which is the runtime the installer and the app both use: it
  set a property that does not exist on .NET Framework. Fixed.
- Settings are versioned, validated and saved atomically. Files from a newer or
  unknown schema are preserved rather than overwritten.

## How this build was validated

On an RTX 4080 Laptop GPU / Intel UHD hybrid machine with mpv v0.41.0:

- 226 playback-plan assertions, including real probes of H.264, HEVC 10-bit,
  AV1, VP9 10-bit and MPEG-4, and non-ASCII filenames.
- 20 settings assertions, plus a check that the harness reports failures instead
  of raising a modal crash dialog.
- Packaging safety and 0.3.2 reconstruction tests on both Windows PowerShell 5.1
  and PowerShell 7.
- The real-media RTX regression on both PowerShell runtimes and on a non-ASCII
  path.
- An isolated install → self-test → upgrade → uninstall cycle under a throwaway
  AppId, with a user settings sentinel byte-identical throughout.
- Four end-to-end runs against the real GPU (RTX, NVIDIA reference,
  Compatibility, Reference), each confirming that the real player arguments
  match the plan fingerprint. RTX processing was observed adapting 1.067× windowed
  → 1.333× fullscreen → off when downscaled → 1.333× restored, with zero dropped
  and zero delayed frames.

Reproduce from `adaptive-media`:

```powershell
dotnet run --project source/tests -c Release
dotnet run --project tests/SettingsTests -c Release
pwsh -File tests/Test-Packaging.ps1
pwsh -File tests/Test-Reconstruction.ps1
pwsh -File tests/Test-RealProbe.ps1 -Engine <installed AdaptiveMedia.Engine.ps1> -MediaPath <1080p file>
pwsh -File source/scripts/Build-Dev.ps1 -Clean -SmokeTest
pwsh -File tests/Test-PlaybackHardware.ps1 -App <AdaptiveMedia.exe> -Media <1080p file> -Resize -CloseLauncherDuringPlayback
```

## Not yet verified anywhere

This is exactly why it is a prerelease.

- Automatic Windows HDR switching and restoration on a real HDR HDMI display.
- HDMI bitstream / Atmos passthrough on a real endpoint.
- Live dependency provisioning on a clean machine that has none of the components.
- Non-NVIDIA GPUs and multi-GPU desktop topologies.
- URL playback end to end, which needs a current yt-dlp.

## Provenance

| | |
|---|---|
| Source commit | `37f33470c908ec4c9a3e1cd47791505cd7281165` |
| Branch | `astra/adaptive-media-upgrade-20260905-112301` |
| Installer | `AdaptiveMediaSetup-0.4.0-rc1-x64.exe` |
| SHA-256 | `0A275527A0694FBF65B9568F53956C3035FE6C0CF0D2EC4B47AB32FABFC73634` |
| Size | 43,903,692 bytes |
| Built (UTC) | 2026-09-06T03:09:18Z |
