# Adaptive Media development channel

This branch is intentionally isolated from the LocalAI source tree. It exists only as the mutable development/download channel for Adaptive Media.

## One-click Windows development flow

Download **`AdaptiveMedia-DevUpdate.cmd` once** and keep it somewhere convenient, such as the Desktop.

After that, double-click it whenever a new development build is available. It downloads the current DevKit payload from this branch, verifies the published SHA-256, extracts the workspace into `%LOCALAPPDATA%\AdaptiveMediaDev`, builds and smoke-tests it, then opens the freshly built installer.

No manual ZIP extraction or terminal navigation is required.
