# AFK AI Friend Bootstrapper

The Friend Bootstrapper is the guided Windows setup path for AFK AI.

It is designed to take a clean Windows 11 machine from a small, inspectable
bootstrap script to a local AI workspace matched to the machine's hardware.

## Entry points

| File | Role |
|---|---|
| `bootstrap.ps1` | Downloads a pinned repository payload, verifies it, ensures PowerShell 7, and hands off |
| `Install-LocalAI.ps1` | Runs the phase-based installer |
| `installer-common.ps1` | Shared installer state and helper functions |
| `installer-state.json` | Local resume state created next to the installer |

The root [README](../README.md) is the user-facing starting point.

## Current installer flow

Current `master` runs these phases:

```text
vet
intent
python
pip
scout
ollama-docker
pulls
compose
seed
secure
self-test
```

In plain language:

1. inspect GPU, VRAM, CPU, RAM, and free disk
2. ask what the user wants AFK AI for
3. install or locate Python 3.12
4. install the editable `localai` package
5. select models for the detected hardware
6. install Ollama and check for Docker
7. pull or build selected models
8. start the compose services
9. seed Open WebUI defaults
10. apply network guardrails
11. run health checks and print the local URLs

## Known Friend Beta preflight gap

Current `master` does not yet prove firmware virtualization, the Windows
virtualization layer, WSL readiness, and Docker engine health before the earlier
setup phases run.

The current `ollama-docker` phase primarily checks whether `docker.exe` exists.
That is not sufficient proof that the local Docker engine is usable.

A clean-machine Friend Beta run demonstrated the consequence: substantial setup
work completed before Docker Desktop exposed the actual Windows virtualization
blocker.

The reviewed implementation contract is now documented in:

[`docs/design/virtualization-docker-preflight.md`](../docs/design/virtualization-docker-preflight.md)

That design requires a live environment preflight, precise recovery guidance,
resume checkpoints, and a second live readiness gate before model downloads.

> [!IMPORTANT]
> The design document describes the next runtime behavior. It is not proof that
> the current Friend Beta tag already implements that behavior.

## Resume state

`installer-state.json` currently records:

- completed phases
- detected hardware
- selected intent
- selected models
- `pending_reboot`

A normal rerun skips phases already recorded as complete.

The current schema is intentionally simple. Known limitations include weak
corrupt-state recovery and a reboot flag without a structured reason. The
merged preflight design specifies a versioned, privacy-bounded checkpoint model
with live revalidation.

Persisted state must remain a resume hint. It must never replace a fresh probe
of safety-critical environment readiness.

## Privacy and network boundary

The installer follows these product rules:

- Docker-published UI, search, voice, and dashboard endpoints use loopback.
- Ollama runs natively on Windows and deliberately uses a Docker-reachable host
  bind so containers can reach it.
- The later secure phase attempts to apply Windows Firewall guardrails on
  physical Wi-Fi and Ethernet adapters.
- A failed or declined firewall action must not be documented as if it
  succeeded.
- Open WebUI's first signup is a local account, not an AFK AI cloud account.
- Software/model downloads and explicitly enabled web search can use the
  internet.
- The installer must not tell users to disable Defender, Smart App Control,
  antivirus, or UAC as a blanket workaround.
- The whole installer should not run elevated simply because one bounded system
  action may require UAC.

See [SECURITY.md](../SECURITY.md) for private vulnerability reporting.

## Building blocks

| Piece | Purpose |
|---|---|
| `localai vet [--json]` | Inspect hardware and emit a capability tier |
| `localai model-scout` | Recommend a bounded model/context combination |
| `localai webui-seed --model <id> --num-ctx <n>` | Seed Open WebUI defaults |
| `installer/tiers.json` | Shared capability thresholds and memory assumptions |

Each component can be exercised independently of the full installer.

## Capability tiers

The current tier system assumes `OLLAMA_KV_CACHE_TYPE=q8_0` and one model slot.

| Tier | VRAM | Broad target |
|---|---:|---|
| S | 16 GB+ | larger local models |
| A | 12 GB | high-quality mid-size models |
| B | 8 GB | balanced local models |
| C | 4 GB | compact models |
| CPU | none | small models with slow generation |

A tier is a safety budget, not a promise that every model of a given parameter
count will fit. Architecture, quantization, context length, KV cache, runtime
overhead, and CPU offload all matter.

## Dry run and resume

Preview the installer without applying its normal work:

```powershell
pwsh -File installer\Install-LocalAI.ps1 -DryRun
```

Resume from existing installer state:

```powershell
pwsh -File installer\Install-LocalAI.ps1 -Resume
```

## Publishing a new candidate

`bootstrap.ps1` is pinned and fail-closed. A release operation must update the
expected tag, commit, and source archive hash together.

Typical maintainer flow:

```powershell
# 1. Create the reviewed annotated tag.
git tag -a v0.1.0 -m 'Friend Bootstrapper v0.1.0'
git push origin v0.1.0

# 2. Resolve the payload commit.
git rev-list -n1 v0.1.0

# 3. Hash the exact source archive consumed by bootstrap.
$u = 'https://github.com/allusionsafk/localai-windows-starter/archive/refs/tags/v0.1.0.zip'
Invoke-WebRequest $u -OutFile "$env:TEMP\localai-v0.1.0.zip"
(Get-FileHash "$env:TEMP\localai-v0.1.0.zip" -Algorithm SHA256).Hash
```

Then update `$Ref`, `$ExpectedCommit`, and `$ExpectedZipSha256` in
`bootstrap.ps1`.

For local development before a reviewed tag exists, `-AllowUnverified` is an
explicit escape hatch. It is not the public distribution path.

### Why the bootstrap comes from `master`

A tag cannot contain a pin to its own future commit identity. The small
bootstrap stub is therefore fetched from `master`, while the payload it
downloads is pinned to the reviewed tag and hash.

Keep the bootstrap tiny, inspectable, and boring.

## Before publishing

Run the public boundary audit:

```powershell
localai public-audit --strict
```

or:

```powershell
pwsh -File ai-public-audit.ps1 -Strict
```

A release should not contain personal paths, hostnames, machine-specific
identifiers, credentials, or other private development residue.
