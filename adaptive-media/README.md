# Adaptive Media 0.3.0

This directory contains the reviewed stable source transport and the automated Windows release gate for Adaptive Media 0.3.0.

The source archive is stored as Base64 text because this repository's earlier Adaptive Media development transport used text-safe artifacts. The accompanying SHA-256 is verified before extraction. GitHub Actions reconstructs the source on a Windows runner, builds the self-contained WPF app, performs the built-in integration and isolated installer smoke tests, and publishes `AdaptiveMediaSetup-0.3.0-x64.exe` to the `v0.3.0` GitHub release.

The actual release source contains the native .NET 10 WPF application, PowerShell playback engine, Inno Setup installer, managed mpv configuration, dependency provisioner, and build script.
