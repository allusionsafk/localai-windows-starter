# Adaptive Media 0.3.1

Patch release for the smooth-motion startup failure in 0.3.0, with clearer in-launcher guidance for playback choices.

## Fixed

- **Gentle smooth motion** no longer causes mpv to exit immediately with code 1.
- **Smooth motion** no longer causes mpv to exit immediately with code 1.
- The motion launch plan now uses `--video-sync-max-factor=10`, inside mpv's supported `1..10` range. Version 0.3.0 mistakenly used `12`.
- The built-in WPF -> `BackendBridge` -> engine integration gate explicitly checks both Gentle and Smooth motion launch plans and rejects any reintroduction of the invalid factor.

## Clearer launcher guidance

The Playback card now explains the choices without turning the UI into a manual:

- **Preset:** Automatic = sensible defaults; Reference = source-faithful; Enhanced = selected processing; Compatibility = fallback path.
- **Upscaling:** Off = native scaling; High quality = EWA Lanczos Sharp; RTX Super Resolution = experimental NVIDIA upscaling.
- **Motion:** Native cadence = no interpolation; Gentle = lighter smoothing; Smooth = strongest smoothing and may produce a soap-opera look.
- **Compression cleanup / debanding:** reduces visible banding and compression artefacts.
- **RTX Video HDR:** experimental NVIDIA HDR enhancement and never enabled automatically.
- Each option also has a concise hover tooltip for a little more detail.

## Unchanged

- Reference mode remains reference-first and does not silently enable interpolation, cleanup/debanding, RTX Video HDR, or RTX Super Resolution.
- High-quality upscaling, compression cleanup/debanding, RTX Video HDR, and RTX Super Resolution remain explicit per-video opt-ins.
- NVIDIA reference playback remains capability-based rather than hard-coded to a specific GPU model.
- Settings continue to live at `%LOCALAPPDATA%\AdaptiveMedia\settings.json` and survive upgrades.
- The installer continues to use the stable Adaptive Media product identity and isolated smoke-test AppId.

## Validation

The Windows release workflow reconstructs the reviewed 0.3.0 source, applies the reviewed stable integration hotfix, applies the 0.3.1 motion/UI/version patch, then performs the native launcher self-test, WPF/backend/engine integration gate, isolated installer install/self-test/integration-test/uninstall smoke test, final installer hash verification, artifact upload, and release publication.

**Still hardware-dependent / not universally verified:** external HDR-TV switching behavior and HDMI bitstream/Atmos passthrough. Dolby Vision processing through mpv/libplacebo is not claimed as native Windows Dolby Vision/Profile 7 FEL passthrough.
