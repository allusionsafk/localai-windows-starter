# AFK AI for Windows

> Friend Beta `0.1.7rc1`

AFK AI is a local-first AI workspace for Windows 11. It brings together Ollama, Open WebUI, SearXNG, local voice, hardware-aware model selection, and a Windows setup path intended for people who do not want to manage the stack by hand.

**[Download AFK AI](https://localai-windows-starter-site.allusionsafk.workers.dev/)** · [Support](SUPPORT.md) · [Security](SECURITY.md) · [Contributing](CONTRIBUTING.md)

## Current boundary

| | |
|---|---|
| Status | Friend Beta `0.1.7rc1` |
| Primary target | Windows 11 with an NVIDIA GPU |
| CPU-only path | Supported with smaller models, but slow |
| Chat | Open WebUI at `http://localhost:3000` |
| Model runtime | Ollama on Windows |
| Optional search | SearXNG at `http://localhost:8080` |
| Licence | MIT |

Friend Beta is still being qualified on clean Windows machines. The pinned public candidate and the development branch are separate things. A newer branch or pull request can contain recovery or installer work that is not part of the website download.

## Install

### Recommended path

Download from the **[AFK AI website](https://localai-windows-starter-site.allusionsafk.workers.dev/)**.

The site serves a pinned Friend Beta installer only after checking its SHA-256. It does not use GitHub `releases/latest` as the AFK AI version authority.

The source file in this repository is still named `Install Local AI.cmd` for compatibility. The website serves the same pinned bytes to the browser as `Install AFK AI.cmd`.

Run the downloaded installer and follow the prompts. Windows may warn about the unsigned Friend Beta script. You can inspect the file before running it.

If Smart App Control blocks the script completely, do not disable Smart App Control for the beta. Use the inspectable source/bootstrap route instead.

### Open chat

After a successful install, Open WebUI is available at:

```text
http://localhost:3000
```

The first Open WebUI account created on that installation becomes the local owner/admin account. It is stored in Open WebUI's local database. It is not an AFK AI cloud account.

## What runs locally

| Service | Endpoint | Purpose |
|---|---|---|
| Open WebUI | `127.0.0.1:3000` | Chat interface |
| SearXNG | `127.0.0.1:8080` | Optional web search |
| Control Center | `127.0.0.1:8765` | Local health and diagnostics |
| Kokoro TTS | `127.0.0.1:8880` | Local voice |
| Ollama | host port `11434` | Native Windows model runtime |

Ollama runs on the Windows host so it can use the GPU directly. Docker-hosted services reach it through the configured host boundary.

## Privacy

AFK AI is local-first, not offline-only.

**Local by design**

- model inference through local Ollama
- Open WebUI account and chat storage
- local UI, voice, search front end, and Control Center
- diagnostics intended to exclude chats, prompts, documents, credentials, and file contents

**Internet access can still occur for**

- setup and software downloads
- model downloads
- updates
- web search you enable
- optional online integrations you choose

Remote access is separate and opt-in. The included Tailscale helper is not enabled automatically.

See [SECURITY.md](SECURITY.md) for the full public security boundary.

## Requirements

Current Friend Beta target:

- Windows 11
- hardware virtualization for the Docker path
- NVIDIA GPU recommended
- roughly 40 GB of free disk for a comfortable first install
- Docker Desktop
- Ollama for Windows
- PowerShell 7 for the full tooling path

The current source also contains Python-based internal tooling. Distribution work is moving toward a more self-owned runtime boundary rather than asking users to manage project internals manually.

## Hardware-aware model fitting

Model Scout evaluates the detected machine before recommending a model/context combination. The broad tiers are:

| Tier | VRAM | Typical target |
|---|---:|---|
| S | 16 GB+ | Larger local models |
| A | 12 GB | High-quality mid-size models |
| B | 8 GB | Balanced local models |
| C | 4 GB | Compact models |
| CPU | none | Small models with slow generation |

A model that loads is not automatically a good fit. Architecture, quantization, context length, KV cache, runtime overhead, RAM, VRAM, and offload all matter.

## Development checkout

For contributors working from source:

```powershell
pip install -e .
copy .env.example .env
localai start
localai health
```

Set a strong `SEARXNG_SECRET` in `.env` before using the search stack.

The internal package and command still use `localai` for continuity. **AFK AI** is the product name. This project is not affiliated with or endorsed by mudler/LocalAI or localai.io.

## Useful commands

| Command | Purpose |
|---|---|
| `localai vet [--json]` | Inspect hardware and capability tier |
| `localai start` | Start the local stack |
| `localai stop` | Stop the local stack |
| `localai health` | Check services and runtime health |
| `localai dashboard` | Open the Control Center |
| `localai model-scout` | Recommend models for the machine |
| `localai warm` | Warm models |
| `localai perf` | Show performance information |
| `localai firewall` | Apply local network guardrails |
| `localai update` | Update supported runtime assets |
| `localai public-audit --strict` | Scan the public tree for machine-specific leaks |

Run `localai --help` for the complete command list.

## Documentation

| Document | Purpose |
|---|---|
| [Documentation index](docs/README.md) | Public docs and engineering records |
| [Support](SUPPORT.md) | Friend Beta support scope |
| [Security](SECURITY.md) | Private vulnerability reporting and privacy boundary |
| [Contributing](CONTRIBUTING.md) | Contribution and test expectations |
| [Friend Beta notes](docs/releases/0.1.7rc1.md) | Pinned candidate scope and known limitations |
| [Installer guide](installer/README.md) | Bootstrap and installer architecture |
| [WebBrain guide](docs/webbrain.md) | Browser/search integration |

## Release note

This repository has also carried historical Adaptive Media release artefacts. Those are not AFK AI versions. For AFK AI, the website pin and the named Friend Beta release record are authoritative.

## Licence

MIT. See [LICENSE](LICENSE).

---

**ALLUSIONS**  
Independent software by Jidan.  
[@allusionsafk](https://github.com/allusionsafk)
