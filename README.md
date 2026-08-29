# AFK AI for Windows

> **Friend Beta 0.1.7rc1** · local-first AI for Windows 11

AFK AI turns a Windows PC into a private, self-hosted AI workspace built around
**Ollama**, **Open WebUI**, **SearXNG**, and local voice.

Your model inference and Open WebUI chat history stay on your machine. Setup,
model downloads, updates, and optional web search can use the internet.

**[Download AFK AI](https://localai-windows-starter-site.allusionsafk.workers.dev/)** ·
[Support](SUPPORT.md) · [Security](SECURITY.md) · [Contributing](CONTRIBUTING.md)

## At a glance

| | |
|---|---|
| **Status** | Friend Beta `0.1.7rc1` |
| **Primary target** | Windows 11 with an NVIDIA GPU |
| **CPU-only fallback** | Supported with smaller models, but slow |
| **Chat** | Open WebUI at `http://localhost:3000` |
| **Optional web search** | SearXNG at `http://localhost:8080` |
| **Model runtime** | Ollama on the Windows host |
| **License** | MIT |

> [!IMPORTANT]
> Friend Beta is still proving the clean-machine install path. The current
> installer does not yet classify every virtualization, WSL, and Docker blocker
> early enough. If setup reaches one of those blockers, keep the exact error
> text instead of guessing at system changes.

## Start here

### 1. Download

Open the **[AFK AI website](https://localai-windows-starter-site.allusionsafk.workers.dev/)**
and choose **Download AFK AI for Windows**.

The website serves a pinned Friend Beta installer only after verifying its
SHA-256. It does not use GitHub `releases/latest` as the download source.

### 2. Run

Double-click **`Install AFK AI.cmd`** and follow the prompts.

Windows may warn about the unsigned Friend Beta script. You can inspect it in
Notepad before running it.

> [!NOTE]
> If Smart App Control blocks the installer without offering a normal run path,
> do not disable Smart App Control just for the beta. Use the inspectable
> PowerShell bootstrap path below instead.

### 3. Open chat

When setup completes, open:

```text
http://localhost:3000
```

The first Open WebUI account you create becomes the local owner/admin account.
It is stored in Open WebUI's local database. It is not an AFK AI cloud account.

After installation, the install folder contains:

```text
Start Local AI.cmd
Stop Local AI.cmd
```

## What AFK AI runs

| Service | Local endpoint | Purpose |
|---|---|---|
| **Open WebUI** | `127.0.0.1:3000` | Chat interface |
| **SearXNG** | `127.0.0.1:8080` | Optional web search |
| **Control Center** | `127.0.0.1:8765` | Local health and diagnostics |
| **Kokoro TTS** | `127.0.0.1:8880` | Local neural voice |
| **Ollama** | host port `11434` | Native Windows model runtime |

Open WebUI, SearXNG, and the other Docker-published user-facing services use
loopback endpoints. Ollama runs natively on Windows so it can use the GPU
directly.

## Privacy without vague promises

AFK AI is **local-first**, not "the internet is never used."

**Stays local by design**

- model inference through local Ollama
- Open WebUI's local account and chat database
- user-facing UI, search, voice, and Control Center endpoints on loopback
- diagnostics designed to exclude chats, prompts, documents, credentials, and
  file contents

**Can use the internet**

- software and model downloads
- updates
- web searches you explicitly enable
- optional online integrations you choose

### Network boundary

Ollama deliberately uses a Docker-reachable Windows host bind so the containers
can reach it. The installer later attempts to apply a Windows Firewall guardrail
for AFK AI ports on physical Wi-Fi and Ethernet adapters.

Remote access is separate and opt-in. The included Tailscale helper is not
enabled automatically.

For the complete public security boundary and private vulnerability reporting,
see **[SECURITY.md](SECURITY.md)**.

## What the installer does

The guided path is intended to become:

```text
download
  -> verify pinned payload
  -> check the Windows environment
  -> inspect hardware
  -> choose a fitting model
  -> install supported prerequisites
  -> configure the local stack
  -> run health checks
  -> open local chat
```

Today, the virtualization, WSL, and Docker preflight is still incomplete.
A real Friend Beta clean-machine run reached Docker Desktop before the actual
Windows virtualization blocker became clear. The next installer milestone is
the early, resumable preflight described in
[`docs/design/virtualization-docker-preflight.md`](docs/design/virtualization-docker-preflight.md).

## Requirements

Current Friend Beta target:

- Windows 11
- hardware virtualization enabled for the Docker path
- NVIDIA GPU recommended
- roughly 40 GB of free disk for a comfortable first install
- Docker Desktop
- Ollama for Windows
- Python 3.12+
- PowerShell 7, which the bootstrapper can install when missing

CPU-only machines can use smaller models. Expect much slower generation.

## PowerShell bootstrap

If you prefer to inspect and launch the bootstrap directly:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/allusionsafk/localai-windows-starter/master/installer/bootstrap.ps1 -OutFile "$env:TEMP\localai-bootstrap.ps1"
powershell -ExecutionPolicy Bypass -File "$env:TEMP\localai-bootstrap.ps1"
```

From an existing checkout:

```powershell
# PowerShell 7
pwsh -ExecutionPolicy Bypass -File installer\bootstrap.ps1

# Windows PowerShell 5.1
powershell -ExecutionPolicy Bypass -File installer\bootstrap.ps1
```

The bootstrap is pinned and fail-closed. It verifies the payload against the
expected tag commit or source archive hash before running it.

The `-ExecutionPolicy Bypass` shown here applies to this process invocation. It
does not permanently change the user's PowerShell execution policy.

## Control CLI

AFK AI currently retains the internal `localai` package and command name.

| Command | Purpose |
|---|---|
| `localai vet [--json]` | Inspect hardware and capability tier |
| `localai start` | Start the local stack |
| `localai stop` | Stop the local stack |
| `localai health` | Check Ollama, services, and search |
| `localai dashboard` | Open the local Control Center |
| `localai model-scout` | Recommend models for the machine |
| `localai warm` | Warm models |
| `localai perf` | Show performance information |
| `localai firewall` | Apply local network guardrails |
| `localai update` | Update supported runtime assets |
| `localai public-audit --strict` | Scan for machine-specific public leaks |

Run `localai --help` for the complete command list.

## Hardware-aware model fitting

The installer does not assume one reference GPU. Model Scout uses the detected
hardware to select a bounded model/context combination.

Current broad tiers:

| Tier | VRAM | Typical target |
|---|---:|---|
| S | 16 GB+ | larger local models |
| A | 12 GB | high-quality mid-size models |
| B | 8 GB | balanced local models |
| C | 4 GB | compact models |
| CPU | none | small models with slow generation |

Actual memory use depends on model architecture, quantization, context length,
KV cache, runtime overhead, and CPU offload. A model that technically loads can
still be a poor recommendation if it leaves too little headroom.

## Manual development bring-up

For contributors and people who want to work from source:

```powershell
pip install -e .
copy .env.example .env
localai start
localai health
```

Set a strong `SEARXNG_SECRET` in `.env` before using the search stack.

## Documentation

| Document | What it covers |
|---|---|
| [Support](SUPPORT.md) | Friend Beta support scope and useful bug reports |
| [Security](SECURITY.md) | Private vulnerability reporting and privacy boundary |
| [Contributing](CONTRIBUTING.md) | Contribution scope and test expectations |
| [Friend Beta notes](docs/releases/0.1.7rc1.md) | Release-candidate truth and known limitations |
| [Installer guide](installer/README.md) | Bootstrap and installer architecture |
| [WebBrain guide](docs/webbrain.md) | Browser automation with a local model |
| [Preflight design](docs/design/virtualization-docker-preflight.md) | Next installer recovery contract |

## Platform direction

Windows 11 with NVIDIA CUDA is the current supported Friend Beta path.

Apple Silicon, Windows ARM64, Linux ARM64, NPUs, AMD acceleration, and other
backends are evaluation or future-validation work. They are not advertised as
supported until installation, chat, health, recovery, and uninstall are proven
on real hardware.

## Project naming

**AFK AI** is the product name.

The repository and internal Python package still use `localai` for continuity.
This project is not affiliated with or endorsed by mudler/LocalAI or
localai.io.

## License

MIT licensed. See [LICENSE](LICENSE).
