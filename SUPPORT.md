# AFK AI Friend Beta support

AFK AI is currently **Friend Beta 0.1.7rc1**. The goal of support during this stage is to turn clean-machine failures into reproducible product fixes without asking testers to understand Docker, WSL, Ollama, or the installer internals.

## Before opening a report

For the easiest current install path, use the AFK AI website:

https://localai-windows-starter-site.allusionsafk.workers.dev/

The current beta targets Windows 11 and is designed around an NVIDIA GPU, Docker Desktop, WSL 2, Ollama, Python 3.12+, and PowerShell 7. Smaller CPU-only models can run, but that is a slow fallback rather than the primary Friend Beta target.

Hardware virtualisation must be enabled for the Docker/WSL path. A current Friend Beta limitation is that the installer does **not yet classify virtualisation, Windows virtualisation features, WSL readiness, and Docker health early enough**. A clean-machine install can therefore reach Docker Desktop before Windows exposes the real blocker. Improving that preflight and recovery path is the next installer milestone.

## Installation or setup problem

Use the **Installation / setup problem** issue form. Include:

- AFK AI version or commit;
- the installer phase or last heading you saw;
- the exact error text;
- whether Windows asked for a restart;
- whether Docker Desktop opens successfully;
- Windows version;
- GPU model and installed memory only when relevant;
- a sanitised diagnostic report if AFK AI can produce one.

Do not post credentials, `.env` contents, private documents, chat text, prompts, cookies, tokens, or unrelated machine information.

## Hardware or compatibility problem

Use the **Hardware / compatibility problem** form when setup is blocked by a GPU, CPU, memory, Windows edition, virtualisation, WSL, or Docker compatibility question. Include what AFK AI detected and what Windows or Docker reported.

## General product bug

Use the **General bug** form for a reproducible problem after setup, such as a control command, health check, local service, model selection, or user-interface behaviour that does not work as described.

## Security or privacy issue

Do not publish sensitive security details in a normal issue. Follow [SECURITY.md](SECURITY.md) and use GitHub private vulnerability reporting.

## Current support expectations

Friend Beta is pre-release software. Clean-machine installation is still being validated, and the first friend run has not yet proven the entire install-to-chat path. Reports that identify one concrete failure and its reproduction are more useful than broad feature requests during this phase.

Unsupported or deferred areas include broad cross-platform installation, production-grade enterprise deployment, billing/licensing, and promises that every third-party Docker/Ollama behaviour is controlled by AFK AI.
