# Adaptive Media 0.3.0

This directory contains the reviewed stable source transport and the automated Windows release gate for Adaptive Media 0.3.0.

The source archive is stored as Base64 text because this repository's earlier Adaptive Media development transport used text-safe artifacts. The accompanying SHA-256 is verified before extraction. GitHub Actions reconstructs the source on a Windows runner, builds the self-contained WPF app, performs the built-in integration and isolated installer smoke tests, and publishes `AdaptiveMediaSetup-0.3.0-x64.exe` to the `v0.3.0` GitHub release.

The actual release source contains the native .NET 10 WPF application, PowerShell playback engine, Inno Setup installer, managed mpv configuration, dependency provisioner, and build script.

## Release publication

`Publish-Release.ps1` performs the GitHub release step and is invoked by the workflow. It probes for an existing `v0.3.0` release, creates it when absent, replaces the assets and refreshes the metadata when present, and then re-downloads the published installer asset to confirm its SHA-256 matches the artifact that passed the build gate. Genuine `gh` failures are re-raised with `gh`'s own output; only the specific "release does not exist" signal is treated as a non-error.
