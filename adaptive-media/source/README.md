# Adaptive Media 0.4.0-rc1

Adaptive Media is a Windows 11 reference-first launcher around **mpv / gpu-next / libplacebo**, with optional per-video enhancements and MPC-BE fallback.

## Release policy

- Reference playback does **not** silently enable interpolation, fake HDR, aggressive sharpening, or cleanup.
- High-quality EWA Lanczos Sharp upscaling, smooth-motion interpolation, debanding, RTX Video Super Resolution, and RTX Video HDR are explicit opt-ins.
- Decoded PCM is the safe audio default. HDMI bitstream is optional.
- Dolby Vision metadata can be processed by mpv/libplacebo, but Adaptive Media does not claim native Windows Dolby Vision/Profile 7 FEL passthrough.
- Settings live in `%LOCALAPPDATA%\AdaptiveMediaPreview\settings.json` and survive upgrades.

## Windows build

```powershell
.\scripts\Build-Dev.ps1 -Clean -SmokeTest
```

The build gate publishes the self-contained .NET 10 WPF app, checks `--self-test`, checks the WPF -> BackendBridge -> PowerShell engine launch-plan path using `--integration-test`, performs an isolated install/self-test/integration-test/uninstall with a dedicated smoke AppId, and finally emits:

`dist\AdaptiveMediaSetup-0.4.0-rc1-x64.exe`

## Validated reference path

On the primary hybrid-NVIDIA validation laptop, reference playback has been validated with `gpu-next`, `winvk`, and `NVDEC`, including zero steady-state decoder/output drops in a real 4K HEVC Dolby Vision/HDR playback sample. Hardware topologies vary, so RTX VSR/HDR remain opt-in D3D11-VPP paths.

## Automatic motion fallback

Gentle and Smooth motion use mpv's display-synchronised interpolation, which
requires the display to present at a stable, known refresh rate. Some displays,
notably laptop panels running a variable refresh rate, do not. Adaptive Media
measures this during playback and falls back to native cadence automatically
when the display is both measurably unstable and measurably dropping frames,
rather than showing broken interpolated playback. The fallback needs all three
of a five-second settling window, an unstable vsync estimate, and a sustained
delayed-frame rate, so a healthy display cannot trigger it. Reference and
Enhanced playback without motion smoothing never use display synchronisation
and are unaffected.

## Known hardware-dependent items

External HDR-TV switching and HDMI bitstream/Atmos passthrough are hardware-dependent and are not claimed as universally verified. The first friend installation is intentionally the second-machine validation.
