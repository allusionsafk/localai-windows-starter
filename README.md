# AFK AI for Windows

> **Friend Beta · 0.1.7rc1** — Windows-first, local-first, and still rough around the edges.

AFK AI is a local-first, ChatGPT-style AI workspace for Windows. The model runs
on your own machine through **Ollama**; Open WebUI provides chat, SearXNG provides
optional web search, and local voice is available through Kokoro.

**Model inference and chat history stay on your PC.** Setup/model downloads and
web searches you explicitly trigger use the internet.

- **Website:** https://localai-windows-starter-site.allusionsafk.workers.dev/
- **Source:** https://github.com/allusionsafk/localai-windows-starter
- **Current beta pin:** `v0.1.7rc1`

> **Windows-first.** The current beta targets Windows 11 with an NVIDIA GPU and
> Docker Desktop. Model sizes and context lengths are chosen from *your*
> hardware rather than a fixed reference machine — see
> [Capability tiers](#capability-tiers).

## What you get

| Service | Local URL | What it is |
|---|---|---|
| Open WebUI | http://localhost:3000 | The chat UI (ChatGPT-style) |
| SearXNG | http://localhost:8080 | Local metasearch front end for optional web search |
| Kokoro TTS | http://localhost:8880 | Local neural voice talk-back (CPU, no VRAM) |
| Ollama | http://localhost:11434 | Model server, running natively on the host |

Open WebUI and SearXNG run in Docker (`docker-compose.yml`); Ollama runs
natively on the Windows host so it can use the GPU directly.

## Privacy and security contract

AFK AI is designed to keep its user-facing services local by default:

- **Local-network guardrails.** Docker-published UI, search, and voice ports bind
  to `127.0.0.1`. Ollama binds to `0.0.0.0:11434` so Docker containers can reach
  the native Windows service; the installer later attempts to apply a Windows
  Firewall block for AFK AI ports on physical Wi-Fi/Ethernet adapters. Sharing
  to your other devices is a separate, explicit opt-in via Tailscale Serve
  (`ai-anywhere.ps1`). Do not treat the Ollama socket itself as loopback-only.
- **Local inference.** Ollama serves the model on your own machine; Open WebUI's
  local database stores the chat UI's account and history on that machine.
- **Internet use is explicit and bounded.** The installer and model downloads
  need the internet. If you enable web search, SearXNG sends search queries to
  external search providers. That is separate from local model inference.
- **Secrets stay local.** `.env` is gitignored; copy `.env.example` to `.env`
  and generate your own `SEARXNG_SECRET`.
- **Third-party startup settings are separate.** AFK AI does not need to run all
  the time, but Docker Desktop and Ollama each have their own Windows startup
  preferences. Use AFK AI's Start/Stop controls for the stack itself.
- **The first Open WebUI account you create becomes the local admin/owner.** It
  is stored in the local Open WebUI database, not an AFK AI cloud account.

For vulnerability reporting and the public security boundary, see
[SECURITY.md](SECURITY.md).

## Quick start

### Easiest: download from the AFK AI site

1. Open the [AFK AI website](https://localai-windows-starter-site.allusionsafk.workers.dev/)
   and choose **Download AFK AI for Windows**. The site serves the installer
   pinned to the current friend-beta tag after verifying its SHA-256.
2. Double-click **`Install AFK AI.cmd`**. Windows may show a security prompt for
   a downloaded unsigned script. You can open the file in Notepad first to
   inspect it before running it.
3. Follow the on-screen prompts. The installer checks the machine, installs
   missing prerequisites where supported, picks a model that fits the GPU, and
   brings up the local stack.
4. If Windows or Docker reports a virtualization/WSL blocker, stop there rather
   than guessing at system changes. The cause may be firmware virtualization, a
   Windows virtualization feature, WSL readiness, Docker state, or a required
   reboot.

> **Current Friend Beta limitation:** virtualization, WSL, and Docker readiness
> are not classified early enough yet. A clean-machine run can reach Docker
> Desktop before the installer exposes the actual Windows blocker. The next
> installer milestone is an early, resumable preflight with one precise recovery
> action. This is documented as a known limitation, not a completed fix.

> If Windows Smart App Control blocks the installer without offering a normal
> run option, **do not disable Smart App Control just for this beta**. Use the
> source/PowerShell path below instead so you can inspect exactly what runs.

After setup, double-click **`Start Local AI.cmd`** / **`Stop Local AI.cmd`** to
start and stop the stack. They live in the install folder,
**`%USERPROFILE%\localai`** (for example,
`C:\Users\You\localai\Start Local AI.cmd`).

### Guided installer (PowerShell)

The Friend Bootstrapper vets your hardware, picks fitting models, brings up the
local stack with the network guardrails described above, and hands off to health
checks.

On a machine that doesn't have this repo yet, open **Windows PowerShell** and
paste these two lines:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/allusionsafk/localai-windows-starter/master/installer/bootstrap.ps1 -OutFile "$env:TEMP\localai-bootstrap.ps1"
powershell -ExecutionPolicy Bypass -File "$env:TEMP\localai-bootstrap.ps1"
```

If you already cloned the repo, run it from the checkout instead:

```powershell
# If you already have PowerShell 7:
pwsh -ExecutionPolicy Bypass -File installer\bootstrap.ps1
# On a clean box with only Windows PowerShell 5.1:
powershell -ExecutionPolicy Bypass -File installer\bootstrap.ps1
```

`bootstrap.ps1` is **pinned and fails closed** — it verifies the download
against a released tag's commit SHA (git) or zip SHA256 (no-git) before running.
See `installer/README.md` for the maintainer publishing steps.

### Manual bring-up

```powershell
# 1. Install the Python control package (Python 3.12+)
pip install -e .

# 2. Configure secrets
copy .env.example .env
#    then set SEARXNG_SECRET in .env to a long random string

# 3. Start the stack (Ollama native + the compose services)
localai start

# 4. Check everything is healthy
localai health

# 5. Open the chat UI
#    http://localhost:3000  → create your local admin account on first visit
```

## The `localai` control CLI

A single Python entry point replaces a folder of loose scripts. Highlights:

| Command | What it does |
|---|---|
| `localai vet [--json]` | Probe GPU/VRAM/CPU/RAM/disk → a capability tier |
| `localai start` / `localai stop` | Bring the stack up / down |
| `localai health` | End-to-end health checks (Ollama, services, search) |
| `localai dashboard` | pywebview Control Center (localhost:8765) |
| `localai model-scout` | Recommend models that fit your VRAM budget |
| `localai webui-seed --model <id> --num-ctx <n>` | Seed Open WebUI defaults |
| `localai warm` / `localai perf` / `localai power` | Warm models, perf + power guards |
| `localai firewall` | Loopback/firewall guardrails |
| `localai update` | Update models, images, and Modelfiles |
| `localai public-audit [--strict]` | Scan for machine-specific markers before sharing |

Run `localai --help` for the full list.

## Capability tiers

Model choice is bounded by VRAM. The installer assumes
`OLLAMA_KV_CACHE_TYPE=q8_0` host-side (halves the KV cache), so each tier's
ceiling model fits its own VRAM:

| Tier | VRAM | Fits (q4 weights, q8_0 KV, 1 slot) | Example |
|---|---|---|---|
| S | ≥16 GB | ~14B dense @32k (~12.5 GB) | qwen2.5:14b class |
| A | 12 GB | ~9B dense @32k (~9.5 GB) | qwen3.5:9b-32k |
| B | 8 GB | ~7B dense @16k (~7.0 GB) | qwen3.5:4b-16k |
| C | 4 GB | ~3B dense @8k (~3.7 GB) | qwen3.5:2b-8k |
| CPU | none | small models only — slow, warned honestly | qwen3.5:2b-8k |

**Honest tradeoff:** large context and large models can still spill to CPU when
VRAM is insufficient, which slows generation. `localai model-scout` shows the
picks *and* the tradeoffs for your box.

## Modelfiles

The included `*.Modelfile` templates build purpose-tuned Ollama models
(grounded/anti-hallucination daily drivers, web-navigation models for
WebBrain, long-context variants). Build one with:

```powershell
ollama create qwen-grounded -f qwen-grounded.Modelfile
```

## Companion scripts (`ai-*.ps1`)

PowerShell utilities that pair with the CLI: `ai-health-monitor`, `ai-perf`,
`ai-power`, `ai-firewall`, `ai-anywhere` (Tailscale Serve), `ai-model-scout`,
`ai-update`, `ai-warm`, `ai-selftest`, `ai-public-audit`, and more.

## Docs

- [SUPPORT.md](SUPPORT.md) — Friend Beta support scope and what to include in a useful report.
- [SECURITY.md](SECURITY.md) — private vulnerability reporting and security/privacy scope.
- [CONTRIBUTING.md](CONTRIBUTING.md) — focused contribution and test expectations.
- [`docs/releases/0.1.7rc1.md`](docs/releases/0.1.7rc1.md) — current Friend Beta release-note draft and known limitations.
- `docs/webbrain.md` — reliable multi-step browser automation with a local model.
- `installer/README.md` — guided installer design, capability tiers, and maintainer publishing steps.

## Requirements

Current friend-beta target:

- Windows 11
- NVIDIA GPU recommended (CPU-only works with smaller models, but is slow)
- Hardware virtualization enabled for Docker Desktop
- Roughly 40 GB of free disk for a comfortable first install
- [Ollama](https://ollama.com) (native Windows install)
- [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- Python 3.12+
- PowerShell 7 (the bootstrapper installs it if missing)

## Platform roadmap

The current installer supports Windows 11 with NVIDIA CUDA. CPU-only systems can
use the smaller-model tier, but the additional platforms below are planned, not
supported today.

Apple Silicon is first. After Windows v1, an M4 pilot will test native Ollama
with Metal acceleration, a core chat path that does not require Docker, and
model fitting based on unified memory instead of dedicated VRAM. Final model
tiers for 16, 24, 32, and 48 GB Macs will come from real measurements.

Later validation lanes include:

- Native Windows ARM64 and Linux ARM64 packaging, with clear CPU fallback when
  an accelerator is unavailable.
- Windows NPUs from Intel, AMD, and Qualcomm through verified runtime providers.
  This is an evaluation path, not a claim that the current Ollama stack uses the
  NPU.
- NVIDIA DGX Spark as a stretch Linux ARM64 and CUDA target. Its unified memory
  will be budgeted from measured available capacity, not treated as all usable
  for a model.

The shared goal is one hardware-capability layer for CUDA, Metal, CPU, and future
NPU providers. Scout and Prepare will use the machine's architecture, memory
model, available capacity, runtime support, and benchmarks instead of relying on
a GPU name alone. No platform will be listed as supported until installation,
chat, health, backup and restore, approval-based updates, sleep/wake where
applicable, and clean uninstall pass on real hardware.

## Project naming

AFK AI is the product name. The repository and internal package still use
`localai` in several places for continuity. This project is **not affiliated
with, or endorsed by, mudler/LocalAI or localai.io**.

## Support and security

Normal setup, compatibility, and product bugs belong in the repository's focused
issue forms. Start with [SUPPORT.md](SUPPORT.md). Security or privacy
vulnerabilities should use the private reporting path in [SECURITY.md](SECURITY.md),
not a public issue containing sensitive details.

## License

MIT — see [LICENSE](LICENSE).
