# Adaptive Media 0.3.0

This directory contains the reviewed stable source transport and the automated Windows release gate for Adaptive Media 0.3.0.

The source archive is stored as Base64 text because this repository's earlier Adaptive Media development transport used text-safe artifacts. The accompanying SHA-256 is verified before extraction. GitHub Actions reconstructs the source on a Windows runner, builds the self-contained WPF app, performs the built-in integration and isolated installer smoke tests, and publishes `AdaptiveMediaSetup-0.3.0-x64.exe` to the `v0.3.0` GitHub release.

The actual release source contains the native .NET 10 WPF application, PowerShell playback engine, Inno Setup installer, managed mpv configuration, dependency provisioner, and build script.

## Dolby Vision P7 to P8.1 execution

The source tree now contains an execution-grade Matroska Dolby Vision evidence
adapter and one deliberately narrow transactional executor for planner-approved
Profile 7 MEL/FEL to Profile 8.1 conversion. It stream-copies and independently
hash-validates the compressed HDR10 base, rewrites RPU with dovi_tool, discards the
enhancement layer, preserves supported tracks/container data, and promotes only an
independently validated temporary output. FEL conversion requires explicit
acknowledgement and always reports lost FEL picture contribution.

Run its non-skipping, provenance-backed real-media regression on Windows with
FFprobe 7.1 on PATH:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File tests/Run-DolbyVisionExecutionTests.ps1
```

The runner verifies or prepares pinned dovi_tool 2.3.3 and MKVToolNix 101.0 under
`.artifacts/dv-tests`. Fixture provenance and the exact preservation/validation
contract are documented in [DOLBY-VISION-CONTRACT.md](DOLBY-VISION-CONTRACT.md).
P5, GPU conversion, Shadow Transcode, installer changes, playback wiring and broad
WPF UI are not part of this executor.

## Release publication

`Publish-Release.ps1` performs the GitHub release step and is invoked by the workflow. It probes for an existing `v0.3.0` release, creates it when absent, replaces the assets and refreshes the metadata when present, and then re-downloads the published installer asset to confirm its SHA-256 matches the artifact that passed the build gate. Genuine `gh` failures are re-raised with `gh`'s own output; only the specific "release does not exist" signal is treated as a non-error.
