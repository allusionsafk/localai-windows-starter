# Adaptive Media v0.1.0

A standalone Windows media playback setup built around MPV/gpu-next/libplacebo with a friendly launcher for files, folders/playlists and URLs.

This is published on a dedicated branch. The normal `localai-windows-starter` `master` branch is untouched.

## Install

1. Download this branch as a ZIP from GitHub.
2. Extract the entire ZIP.
3. Double-click **`AdaptiveMediaSetup.cmd`**.
4. The bootstrap reconstructs the launcher and verifies its SHA-256 before opening the graphical installer.
5. Keep the recommended options selected and click **Install**.
6. Launch **Adaptive Media** from the Desktop or Start Menu.

The launcher supports:

- Open one or more local video/audio files.
- Open a folder as a naturally sorted playlist.
- Open direct network media or yt-dlp-supported public URLs.
- Drag files/folders into the launcher.
- Automatic/reference/enhanced/compatibility playback profiles.
- Conservative HDMI HDR switching with state restoration when exactly one eligible HDMI HDR target is present.
- Safe PCM audio by default, with optional HDMI AC-3/E-AC-3/TrueHD/DTS-HD passthrough.
- MPC-BE as an optional compatibility fallback.
- Hardware/display/audio diagnostics.

## Security model

Adaptive Media installs per-user. It does not disable Defender, add antivirus exclusions, modify the firewall, install codec packs, import browser cookies, or write HKLM registry settings. MPV and yt-dlp fallback downloads come from their official GitHub releases and GitHub-provided SHA-256 digests are checked when available.

## Important limitation

This build was statically checked in a Linux build environment; the WinForms UI, Windows DisplayConfig HDR calls, HDMI/audio routing and playback on the target MSI laptop were not runtime-tested here. Dolby Vision source processing is not the same as native Dolby Vision HDMI metadata passthrough, and Adaptive Media does not claim native DV passthrough.

Published launcher SHA-256 after reconstruction:

`ebf267afbb19866fc7040ce687ee43b013378706fe47f7040e9a78e36f4c2d02`
