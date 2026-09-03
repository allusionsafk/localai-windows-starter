# Adaptive Media 0.3.2

A correctness release. Two real playback problems are fixed, both found by
running the player against measured hardware rather than by looking at it.

## Fixed: the Compatibility preset was not actually a compatibility path

On any machine with an NVIDIA GPU, choosing **Compatibility** still ran the
managed NVIDIA renderer. The guard that was meant to exclude it was written as

```powershell
if (Test-NvidiaGpuPresent -and $profile -ne 'compatibility')
```

which PowerShell parses in command mode: it calls the function with the literal
arguments `-and`, `$profile`, `-ne`, `compatibility`, discards them, and tests
only the function's own result. The Compatibility exclusion was a silent no-op.

Measured on RTX 4080 Laptop hardware through mpv's IPC:

| launch | gpu-api | gpu-context | hwdec |
|---|---|---|---|
| Compatibility, before | vulkan | winvk | nvdec |
| Compatibility, after | d3d11 | d3d11 | d3d11va-copy |

Compatibility is the fallback you reach for when the managed path misbehaves, so
on the machines that needed it most it did nothing. It now selects the explicit
D3D11 renderer as documented. Reference, Automatic and Enhanced playback are
unchanged, and the managed NVIDIA path still uses Vulkan/winvk/NVDEC.

## New: automatic motion fallback on displays that cannot present stably

Gentle and Smooth motion use mpv's display-synchronised interpolation, which
requires the display to present at a stable, known refresh rate. Not every
display does. On the 240 Hz laptop panel used for validation, measured
presentation wanders between 120 and 231 Hz with a vsync-jitter of 0.21 to 1.01
where a healthy display sits near 0.01, and interpolated playback accumulates
delayed frames and dropped frames continuously for as long as it runs.

This is not specific to Adaptive Media - stock mpv with no configuration at all
and the same display-sync options behaves worse on the same machine - but it is
Adaptive Media's problem to handle. Rather than present visibly broken
interpolated playback, the managed configuration now detects the condition and
falls back to native cadence by itself.

The fallback requires all three of a settling window, a measurably unstable
display, and measurable harm to playback, so a healthy display that is merely
slow to converge cannot trigger it. Measured effect on the validation machine,
same file and same window:

| | delayed frames | dropped frames |
|---|---|---|
| Smooth motion, before | 130 - 273 | 3 - 47 |
| Smooth motion, after | 0 | 0 |

Reference and Enhanced playback without motion smoothing never use display
synchronisation and are unaffected.

## Playback diagnostics are now installed

The installer places an objective playback diagnostics tool in the Start menu
under **Adaptive Media Playback Diagnostics**. It launches the real production
launch plan, reads the renderer, decoder, refresh and frame-timing state back
out of mpv over IPC, and writes a report to
`%LOCALAPPDATA%\AdaptiveMedia\certification\0.3.2-hardware.json`. It is there
for support, and an ordinary install does not run it.

## Unchanged

- Reference playback remains reference-first and does not silently enable
  interpolation, cleanup/debanding, RTX Video HDR, or RTX Super Resolution.
- High-quality upscaling, compression cleanup/debanding, RTX Video HDR, and RTX
  Super Resolution remain explicit per-video opt-ins.
- Decoded PCM remains the safe audio default; HDMI bitstream stays optional.
- NVIDIA reference playback remains capability-based rather than tied to a
  specific GPU model.
- Settings continue to live at `%LOCALAPPDATA%\AdaptiveMedia\settings.json` and
  survive upgrades.

## Validation

The release workflow reconstructs the reviewed source, verifies its SHA-256,
applies the reviewed patch stack, asserts the renderer and integration
invariants, runs the native launcher self-test and the WPF to backend to engine
launch-plan integration gate, performs an isolated install/self-test/
integration-test/uninstall smoke test, and publishes the exact installer whose
SHA-256 was certified. The published build was additionally certified on real
RTX 4080 Laptop hardware with the bundled diagnostics tool: managed NVIDIA
renderer confirmed as `vulkan`/`winvk`/`fifo` with NVDEC, zero output frame
drops, zero decoder frame drops, and zero delayed frames in steady state.

**Still hardware-dependent and not claimed as universally verified:** external
HDR-TV switching behaviour, and HDMI bitstream/Atmos passthrough. Dolby Vision
processing through mpv/libplacebo is not native Windows Dolby Vision or
Profile 7 FEL passthrough and is not claimed as such.
