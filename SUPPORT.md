# AFK AI support

AFK AI is currently Friend Beta `0.1.7rc1`.

Support at this stage is focused on reproducible Windows installation, runtime, chat, model, and hardware problems.

**[Download AFK AI](https://localai-windows-starter-site.allusionsafk.workers.dev/)**

## Current target

| | |
|---|---|
| OS | Windows 11 |
| Accelerated path | NVIDIA GPU |
| CPU-only path | Smaller models, slower generation |
| Container runtime | Docker Desktop |
| Model runtime | Ollama for Windows |
| Recommended free disk | About 40 GB for a comfortable first install |

Friend Beta is pre-release software. The pinned public candidate is not the same thing as newer development branches and pull requests.

## Installation problem

Use the **Installation / setup problem** issue form.

Include:

- AFK AI version, tag, or commit
- installer phase or last status shown
- exact error text
- whether Windows requested a restart
- whether Docker Desktop opens successfully
- Windows version
- GPU model when relevant
- a sanitised diagnostic report when available

Do not post credentials, `.env` contents, private documents, chats, prompts, cookies, tokens, or unrelated machine information.

## Hardware or compatibility problem

Use the **Hardware / compatibility problem** form for issues involving:

- GPU or CPU support
- memory or disk pressure
- Windows version
- hardware virtualization
- WSL
- Docker compatibility

Include what AFK AI detected and what Windows, WSL, Docker, or Ollama reported.

## Product bug

Use the **General bug** form for a reproducible problem after setup, including:

- chat or Open WebUI
- start/stop behaviour
- service health
- model selection
- Control Center behaviour
- search or local voice
- behaviour that disagrees with the documentation

## Security or privacy

Do not publish sensitive security details in a normal issue.

Use the private reporting path in [SECURITY.md](SECURITY.md).

## Good reports

A short report with one reproducible failure is more useful than a broad list of symptoms. Include enough evidence to reproduce the problem, then stop. Raw machine dumps are rarely useful and can expose unrelated information.
