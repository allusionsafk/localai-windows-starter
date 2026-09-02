# Adaptive Media 0.3.1

Patch release for the smooth-motion startup failure in 0.3.0.

## Fixed

- **Gentle smooth motion** no longer causes mpv to exit immediately with code 1.
- **Smooth motion** no longer causes mpv to exit immediately with code 1.
- The motion launch plan now uses `--video-sync-max-factor=10`, which is inside mpv's supported `1..10` range. Version 0.3.0 mistakenly used `12`.
- The built-in WPF -> `BackendBridge` -> engine integration gate now explicitly checks both Gentle and Smooth motion launch plans and rejects any reintroduction of the invalid factor.

## Unchanged

- Reference mode remains reference-first and does not silently enable interpolation, cleanup/debanding, RTX Video HDR, or RTX Super Resolution.
- High-quality upscaling, compression cleanup/debanding, RTX Video HDR, and RTX Super Resolution remain explicit per-video opt-ins.
- NVIDIA reference playback remains capability-based rather than hard-coded to a specific GPU model.
- Settings continue to live at `%LOCALAPPDATA%\AdaptiveMedia\settings.json` and survive upgrades.
- The installer continues to use the stable Adaptive Media product identity and isolated smoke-test AppId.

## Validation

The Windows release workflow reconstructs the reviewed 0.3.0 source, applies the already-reviewed stable integration hotfix, applies the 0.3.1 motion/version patch, then performs the native launcher self-test, WPF/backend/engine integration gate, isolated installer install/self-test/integration-test/uninstall smoke test, final installer hash verification, artifact upload, and release publication.

**Still hardware-dependent / not universally verified:** external HDR-TV switching behavior and HDMI bitstream/Atmos passthrough. Dolby Vision processing through mpv/libplacebo is not claimed as native Windows Dolby Vision/Profile 7 FEL passthrough.
