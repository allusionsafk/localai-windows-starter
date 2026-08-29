# AFK AI Friend Beta support

AFK AI is currently **Friend Beta 0.1.7rc1**.

Support during this stage has one goal: turn clean-machine failures into
reproducible product fixes without asking testers to understand Docker, WSL,
Ollama, or installer internals.

**[Download AFK AI](https://localai-windows-starter-site.allusionsafk.workers.dev/)**

## Current target

| | |
|---|---|
| **OS** | Windows 11 |
| **Accelerated path** | NVIDIA GPU |
| **CPU-only fallback** | Supported with smaller models, but slow |
| **Container runtime** | Docker Desktop |
| **Model runtime** | Ollama for Windows |
| **Disk** | Roughly 40 GB recommended for a comfortable first install |

Hardware virtualization must be enabled for the Docker path.

> [!IMPORTANT]
> The current Friend Beta does not yet classify every virtualization, WSL, and
> Docker blocker early enough. A clean-machine install can reach Docker Desktop
> before the actionable Windows blocker is clear. Keep the exact error text if
> this happens.

## Installation or setup problem

Use the **Installation / setup problem** issue form.

Include:

- AFK AI version or commit
- installer phase or last heading shown
- exact error text
- whether Windows requested a restart
- whether Docker Desktop opens successfully
- Windows version
- GPU model and installed memory, only when relevant
- a sanitized AFK AI diagnostic report, if one is available

Do not post credentials, `.env` contents, private documents, chats, prompts,
cookies, tokens, or unrelated machine information.

## Hardware or compatibility problem

Use the **Hardware / compatibility problem** form when setup is blocked by:

- GPU or CPU support
- memory
- Windows edition
- hardware virtualization
- WSL
- Docker compatibility

Include what AFK AI detected and what Windows or Docker reported.

## General product bug

Use the **General bug** form for a reproducible problem after setup, such as:

- a control command
- a health check
- a local service
- model selection
- Control Center behavior
- documented behavior that does not match the product

## Security or privacy issue

Do not publish sensitive security details in a normal issue.

Follow [SECURITY.md](SECURITY.md) and use GitHub private vulnerability
reporting.

## What Friend Beta support means

Friend Beta is pre-release software. Clean-machine installation is still being
validated, and the first friend run has not yet proven the complete install to
chat path.

A report that identifies one concrete failure and how to reproduce it is more
useful right now than a broad feature request.

Deferred areas include broad cross-platform installation, enterprise
deployment, billing, licensing, and promises about third-party Docker or Ollama
behavior that AFK AI does not control.
