# localai Friend Bootstrapper

A guided, mostly-automatic setup that stands up a **secure, loopback-only** localai
stack on a clean-ish Windows machine — matched to the box's hardware and to what
the user actually wants it for.

> **Status:** the Python building blocks below are implemented and tested
> (`localai vet`, `localai webui-seed`, `installer/tiers.json`). The guided
> PowerShell entry points (`bootstrap.ps1`, `Install-LocalAI.ps1`) are in
> progress. Until they land, use the building blocks directly or follow the
> repo's main `README.md`.

## What it does

1. **Vets the system** — GPU/VRAM, CPU, RAM, free disk, Docker presence — and maps
   it to a capability **tier** (S/A/B/C/CPU) that bounds how large a model can run.
2. **Asks intent** — chat / coding / web browsing / voice — with sane defaults.
3. **Chooses models** — runs the scout filtered to the tier's VRAM budget and the
   chosen intent, shows the picks and honest tradeoffs, and lets the user confirm.
4. **Installs components** — Ollama, Docker Desktop (detect-first), the chosen
   models + Modelfiles, brings up the compose stack, and seeds the Open WebUI DB.
5. **Secures by default** — loopback-only binds, the physical-adapter firewall
   block, the WinNAT port-3000 fix. **No LAN/remote exposure unless explicitly
   opted in.**
6. **Self-tests + hands off** — gates on `localai health`, then prints URLs and how
   to start/stop/change models.

## What it NEVER does (the security contract)

- **Never exposes services to the network** without an explicit, separate opt-in.
  Every bind is `127.0.0.1` by default; the firewall block rule guards the one
  `0.0.0.0` bind (Ollama) that Docker needs.
- **Never registers autostart** — no scheduled tasks, no Docker restart policies,
  no auto-launch. Starting the stack is always a manual choice.
- **Never creates your Open WebUI account** — the first browser signup becomes
  admin; the installer only prints that instruction.
- **Never runs the whole thing elevated** — only the firewall/WinNAT steps
  self-elevate; everything else runs as your normal user.

## Building blocks (shipped today)

| Piece | What it is |
|---|---|
| `localai vet [--json]` | Probes hardware → capability tier. `--json` emits one line for the orchestrator. |
| `localai webui-seed --model <id> --num-ctx <n>` | Seeds Open WebUI's SQLite config (per-model `think`/`num_ctx`/`presence_penalty`, defaults). Refuses loudly on an unexpected DB schema. `--dry-run` prints the plan. |
| `installer/tiers.json` | Single source of truth for tier thresholds + VRAM math, mirrored by the PowerShell vet phase. Its KV/weights/overhead constants are kept in lockstep with `model_scout` by a test. |

## Capability tiers

Assumes the installer sets `OLLAMA_KV_CACHE_TYPE=q8_0` host-side (halves KV cache),
so each tier's ceiling model fits its own VRAM at 32k/16k/8k context:

| Tier | VRAM | Fits (q4 weights, q8_0 KV, 1 slot) | Example |
|---|---|---|---|
| S | ≥16 GB | ~14B dense @32k (12.5 GB) | qwen2.5:14b class |
| A | 12 GB | ~9B dense @32k (9.5 GB) | qwen3.5:9b-32k |
| B | 8 GB | ~7B dense @16k (7.0 GB) | qwen2.5:7b class |
| C | 4 GB | ~3B dense @8k (3.7 GB) | qwen2.5:3b class |
| CPU | none | tiny/MoE only — slow, warned honestly | qwen 4B-A0.6 class |

## Publishing (maintainer only)

`bootstrap.ps1` is **pinned and fails closed**: it refuses to run unless the
download is verified against a known commit SHA (git path) or zip SHA256 (no-git
path). After cutting a release tag, fill the two pins so friends get a verified
download:

```powershell
# 1. Cut and push the tag at the reviewed commit:
git tag -a v0.1.0 -m 'Friend Bootstrapper v0.1.0'
git push origin v0.1.0

# 2. Get the commit SHA the tag points to:
git rev-list -n1 v0.1.0

# 3. Get the SHA256 of the tag's source zip:
$u = 'https://github.com/allusionsafk/localai-windows-starter/archive/refs/tags/v0.1.0.zip'
Invoke-WebRequest $u -OutFile "$env:TEMP\localai-v0.1.0.zip"
(Get-FileHash "$env:TEMP\localai-v0.1.0.zip" -Algorithm SHA256).Hash
```

Set those as the `$ExpectedCommit` and `$ExpectedZipSha256` defaults in
`bootstrap.ps1` (and bump `$Ref`). For local dev testing before a tag exists, run
with `-AllowUnverified`.

> **Before publishing a new tag:** run `localai public-audit --strict` (or
> `pwsh -File ai-public-audit.ps1 -Strict`) so no machine-specific markers —
> user paths, hostnames, GPU model, tailnet names — slip into the release.
