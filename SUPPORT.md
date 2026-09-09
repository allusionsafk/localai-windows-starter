# AFK LocalAI Friend Beta support

AFK LocalAI `0.2.0-rc1` is prerelease software. Friend Beta support focuses on
turning clean-machine setup and recovery failures into reproducible product
fixes without asking testers to understand Docker, WSL, or PowerShell internals.

## Before reporting a setup problem

1. Launch AFK LocalAI again. A partial setup should return to its saved
   checkpoint and recheck the live machine state.
2. Use the recovery action shown in the app. If Windows requested a restart,
   restart before choosing **Try again**.
3. Open **Start Menu → AFK LocalAI → Diagnostics**.
4. Review the newest report in
   `%LOCALAPPDATA%\AFK LocalAI\Diagnostics` before sharing it.

The Diagnostics shortcut runs without a visible terminal. Reports redact the
current profile path, but you should still check them for information you do
not want to publish.

## What to include

- AFK LocalAI version shown in **About AFK LocalAI**
- the exact setup phase, status code, and message shown
- whether AFK LocalAI offered **Resume setup**, **Try again**, or a restart
- Windows version
- whether Docker Desktop opens successfully
- GPU model and memory only when the problem is hardware-related
- a sanitized AFK LocalAI diagnostic report when useful

Do not include `.env` contents, credentials, tokens, cookies, chats, prompts,
documents, model inputs, or unrelated machine details.

## Issue types

Use the repository's **Installation / setup problem** form for installation,
virtualization, WSL, Docker, prerequisite, resume, upgrade, or uninstall bugs.

Use **Hardware / compatibility problem** for GPU, CPU, memory, Windows edition,
or unsupported-runtime questions.

Use **General bug** for a reproducible failure after setup, such as starting the
workspace, health reporting, model selection, or opening local chat.

For a security or privacy issue, do not open a public issue. Follow
[SECURITY.md](SECURITY.md) and use GitHub private vulnerability reporting.

## Current support boundary

The primary Friend Beta target is Windows 11 x64 with hardware virtualization,
a healthy local Docker Desktop Linux-container engine, WSL 2 where Docker needs
it, and an NVIDIA GPU. CPU-only use is supported with smaller models but can be
slow. Broad enterprise deployment, Windows Server, ARM64, macOS, Linux desktop,
AMD acceleration, and NPU paths are not qualified by this candidate.
