# Adaptive Media 0.3.0

First stable friend-ready release of the Adaptive Media Windows launcher.

## Release highlights

- Native self-contained .NET 10 WPF launcher.
- Reference-first mpv/gpu-next/libplacebo playback policy.
- NVIDIA reference path supports the validated `winvk` + `NVDEC` configuration without model-specific RTX 4080 hard-coding.
- Per-video **High quality** EWA Lanczos Sharp upscaling.
- Opt-in **Gentle** and **Smooth Motion** interpolation.
- Opt-in compression cleanup/debanding.
- Experimental opt-in NVIDIA RTX Super Resolution and RTX Video HDR paths.
- URL/stream playback through yt-dlp.
- MPC-BE compatibility fallback.
- Settings stored outside the install directory at `%LOCALAPPDATA%\AdaptiveMedia\settings.json`, so upgrades preserve them.
- Stable per-user install location and stable product AppId.

## Final stabilization fixes

- Preserves the complete self-contained WPF publish tree in the installer staging directory.
- Keeps Windows `FileVersion` / `ProductVersion` numeric at `0.3.0.0` while presenting the stable app as `0.3.0`.
- Removes the PowerShell automatic-`$args` collision from the production headless MPV launch path.
- Adds a headless WPF -> `BackendBridge` -> engine launch-plan integration check covering Reference, HQ upscale, Smooth+cleanup, and Compatibility semantics.
- Installer smoke tests use a dedicated smoke AppId and therefore do not replace or pollute the real Adaptive Media uninstall entry.

## Validation status

The primary hybrid-NVIDIA validation machine has demonstrated healthy real playback on the `gpu-next` / `winvk` / `NVDEC` reference path, including a real 4K HEVC Dolby Vision/HDR sample with zero steady-state decoder/output drops in the known-good run. The stable build additionally performs automated launcher self-tests, launch-plan integration checks, and isolated installer install/self-test/integration-test/uninstall checks on GitHub's Windows runner before the release asset is created.

**Not universally verified:** external HDR-TV switching behaviour and HDMI bitstream/Atmos passthrough depend on the actual display/AVR topology. Dolby Vision processing through mpv/libplacebo is not claimed as native Windows Dolby Vision/Profile 7 FEL passthrough.
