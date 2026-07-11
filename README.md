# localai-windows-starter

A private, local AI workspace for Windows — a self-hosted alternative to
cloud chat apps. Runs a chat UI, a private web-search engine, and local
voice, with models served by **Ollama** on your own GPU. Nothing leaves your
PC unless you explicitly opt in.

> **Windows-first.** The stack targets Windows 11 with an NVIDIA GPU + Docker
> Desktop. Model sizes and context lengths are chosen from *your* hardware, not
> a fixed reference machine — see [Capability tiers](#capability-tiers).

## What you get

| Service | URL (loopback-only by default) | What it is |
|---|---|---|
| Open WebUI | http://localhost:3000 | The chat UI (ChatGPT-style) |
| SearXNG | http://localhost:8080 | Private metasearch for in-chat web search |
| Kokoro TTS | http://localhost:8880 | Local neural voice talk-back (CPU, no VRAM) |
| Ollama | http://localhost:11434 | Model server, running natively on the host |

Open WebUI and SearXNG run in Docker (`docker-compose.yml`); Ollama runs
natively on the Windows host so it can use the GPU directly.

## Security contract

This stack is **loopback-only and manual-start by design**:

- **No network exposure by default.** Every port binds to `127.0.0.1`. Sharing
  to your other devices is a separate, explicit opt-in via Tailscale Serve
  (`ai-anywhere.ps1`) — never a raw LAN/`0.0.0.0` bind.
- **No autostart.** No scheduled tasks, no Docker restart policies, no
  auto-launch. Starting the stack is always a manual choice.
- **Secrets stay local.** `.env` is gitignored; copy `.env.example` to `.env`
  and generate your own `SEARXNG_SECRET`.
- **The first Open WebUI account you create becomes the local admin/owner.** It
  is stored only in the local database.

## Quick start

### Easiest: double-click (no PowerShell needed)

1. Download **`Install Local AI.cmd`** from the
   [latest release](https://github.com/allusionsafk/localai-windows-starter/releases/latest).
2. Double-click it. Windows shows a security box because the file was downloaded —
   click **More info → Run anyway** (blue box) or **Run** (yellow box). This is
   expected; it's a short script you can open in Notepad first to read.
   If there is **no "Run anyway" option at all**, your PC has **Smart App Control**
   turned on, which blocks unsigned scripts outright — turn it off under Windows
   Security → App & browser control → Smart App Control, or use the PowerShell
   method below.
3. Follow the on-screen prompts. It picks models that fit *your* PC and sets
   everything up. When it finishes, your chat is at http://127.0.0.1:3000.

After setup, double-click **`Start Local AI.cmd`** / **`Stop Local AI.cmd`** to
start and stop it — no typing. Both live in the install folder,
**`%USERPROFILE%\localai`** (e.g. `C:\Users\You\localai\Start Local AI.cmd`).

### Guided installer (PowerShell)

The Friend Bootstrapper vets your hardware, picks fitting models, brings up the
stack loopback-only, and hands off to health checks.

On a machine that doesn't have this repo yet, open **Windows PowerShell**
(press Start, type "powershell", press Enter) and paste these two lines:

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
#    http://localhost:3000  → create your admin account on first visit
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
Nanobrowser, long-context variants). Build one with:

```powershell
ollama create qwen-grounded -f qwen-grounded.Modelfile
```

## Companion scripts (`ai-*.ps1`)

PowerShell utilities that pair with the CLI: `ai-health-monitor`, `ai-perf`,
`ai-power`, `ai-firewall`, `ai-anywhere` (Tailscale Serve), `ai-model-scout`,
`ai-update`, `ai-warm`, `ai-selftest`, `ai-public-audit`, and more.

## Docs

- `docs/nanobrowser.md` — reliable multi-step browser automation with a local
  model.
- `installer/README.md` — the guided installer design, capability tiers, and
  maintainer publishing steps.

## Requirements

- Windows 11 with an NVIDIA GPU (CPU-only works but is slow — see the tiers)
- [Ollama](https://ollama.com) (native Windows install)
- [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- Python 3.12+
- PowerShell 7 (the bootstrapper installs it if missing)

## License

MIT — see [LICENSE](LICENSE).
