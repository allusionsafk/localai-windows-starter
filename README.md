# AFK AI for Windows

> Friend Beta `0.1.7rc1`

AFK AI is a local-first AI workspace for Windows 11. It combines Ollama, Open WebUI, SearXNG, local voice, hardware-aware model selection, and a guided Windows setup path.

[Download](https://localai-windows-starter-site.allusionsafk.workers.dev/) | [Support](SUPPORT.md) | [Security](SECURITY.md) | [Contributing](CONTRIBUTING.md)

## At a glance

| | |
|---|---|
| Status | Friend Beta `0.1.7rc1` |
| Primary target | Windows 11 with an NVIDIA GPU |
| CPU-only path | Smaller models with slower generation |
| Chat | Open WebUI at `http://localhost:3000` |
| Model runtime | Ollama for Windows |
| Optional search | SearXNG at `http://localhost:8080` |
| Licence | MIT |

The public Friend Beta is pinned separately from development. Branches and pull requests can contain work that is not included in the current download.

## Install

Download AFK AI from the [project website](https://localai-windows-starter-site.allusionsafk.workers.dev/).

The website serves a pinned Friend Beta installer after verifying its SHA-256. It does not use GitHub `releases/latest` as the AFK AI version authority.

The source file remains named `Install Local AI.cmd` for compatibility. The website serves the same pinned bytes as `Install AFK AI.cmd`.

Run the downloaded installer and follow the prompts. Windows may warn about the unsigned Friend Beta script. The file can be inspected before it is run.

If Smart App Control blocks the script, do not disable Smart App Control for the beta. Use the inspectable source/bootstrap route instead.

## Local services

| Service | Endpoint | Purpose |
|---|---|---|
| Open WebUI | `127.0.0.1:3000` | Chat interface |
| SearXNG | `127.0.0.1:8080` | Optional web search |
| Control Center | `127.0.0.1:8765` | Health and diagnostics |
| Kokoro TTS | `127.0.0.1:8880` | Local voice |
| Ollama | host port `11434` | Native Windows model runtime |

Ollama runs on the Windows host so it can use the GPU directly. Docker-hosted services reach it through the configured host boundary.

After installation, open `http://localhost:3000`. The first Open WebUI account created on that installation becomes its local owner/admin account. It is stored in Open WebUI's local database, not in an AFK AI cloud account.

## Privacy

AFK AI is local-first, not offline-only.

Local by design:

- model inference through local Ollama
- Open WebUI account and chat storage
- local UI, voice, search front end, and Control Center
- diagnostics intended to exclude chats, prompts, documents, credentials, and file contents

Internet access can still be used for:

- setup and software downloads
- model downloads
- updates
- web search you enable
- optional online integrations you choose

Remote access is separate and opt-in. The included Tailscale helper is not enabled automatically.

See [SECURITY.md](SECURITY.md) for reporting and security details.

## Requirements

Current Friend Beta target:

- Windows 11
- hardware virtualization for the Docker path
- NVIDIA GPU recommended
- about 40 GB of free disk for a comfortable first install
- Docker Desktop
- Ollama for Windows
- PowerShell 7 for the full tooling path

The source tree also contains Python-based engineering tools. Distribution work is moving toward a more self-contained runtime path so end users do not need to manage project internals.

## Model fitting

Model Scout evaluates the detected machine before recommending a model and context combination.

| Tier | VRAM | Typical target |
|---|---:|---|
| S | 16 GB+ | Larger local models |
| A | 12 GB | High-quality mid-size models |
| B | 8 GB | Balanced local models |
| C | 4 GB | Compact models |
| CPU | none | Small models with slow generation |

A successful load does not by itself mean a model is a good fit. Architecture, quantization, context length, KV cache, runtime overhead, RAM, VRAM, and offload all matter.

## Development

For a source checkout:

```powershell
pip install -e .
copy .env.example .env
localai start
localai health
```

Set a strong `SEARXNG_SECRET` in `.env` before using the search stack.

The internal package and command still use `localai` for continuity. **AFK AI** is the product name. This project is not affiliated with or endorsed by mudler/LocalAI or localai.io.

Common commands:

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
| [Support](SUPPORT.md) | Support scope and issue routing |
| [Security](SECURITY.md) | Private vulnerability reporting |
| [Contributing](CONTRIBUTING.md) | Contribution and test expectations |
| [Friend Beta notes](docs/releases/0.1.7rc1.md) | Current public candidate |
| [Installer guide](installer/README.md) | Bootstrap and installer architecture |
| [WebBrain guide](docs/webbrain.md) | Browser and search integration |

Historical Adaptive Media release artefacts also exist in this repository. They are not AFK AI versions. For AFK AI, use the website pin and the named Friend Beta release record.

## Licence

MIT. See [LICENSE](LICENSE).

**ALLUSIONS**  
Independent software by Jidan.
