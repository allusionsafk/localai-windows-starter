# AFK LocalAI for Windows

> Friend Beta `0.2.0-rc1` · a guided, local-first AI workspace for Windows 11

AFK LocalAI installs a private AI workspace built around Ollama, Open WebUI,
SearXNG, and local voice. The normal distribution is one Windows installer:

```text
AFKLocalAISetup-0.2.0-rc1-x64.exe
```

No repository clone, developer tools, manual PowerShell, or PATH editing is
part of the supported user path.

[Support](SUPPORT.md) · [Security](SECURITY.md) ·
[Release candidate notes](docs/releases/0.2.0-rc1.md) ·
[Install, upgrade, and uninstall](docs/install-upgrade-uninstall.md)

> [!IMPORTANT]
> `0.2.0-rc1` is a prerelease candidate. Only an asset attached to the matching
> GitHub prerelease with its `.sha256.txt` file should be shared with testers.
> A source checkout or locally rebuilt EXE is not the published candidate.

## Install

1. Download `AFKLocalAISetup-0.2.0-rc1-x64.exe` from the matching AFK LocalAI
   GitHub prerelease.
2. Double-click the installer.
3. Keep the default per-user location and optionally choose a Desktop shortcut.
4. Leave **Launch AFK LocalAI** selected.
5. Follow the setup screen until AFK LocalAI reports that the local workspace
   is ready.

Windows may show an unsigned-app warning during Friend Beta. Do not disable
Defender, Smart App Control, antivirus, or UAC to bypass a block. Confirm that
the downloaded file has the SHA-256 published beside the release asset, or ask
the tester coordinator for a newly qualified build.

## Guided first run

AFK LocalAI checks the machine before it downloads models or changes the local
runtime. The setup screen reports:

- Windows version and architecture
- firmware virtualization capability and current Windows virtualization state
- WSL installation, version, health, and restart requirements
- Docker Desktop installation, engine state, context, and container mode
- GPU, VRAM, CPU, memory, and supported model tier
- conflicting or damaged prior AFK LocalAI state

When a prerequisite is missing, the app presents one bounded recovery action
or a precise manual instruction. Potentially disruptive firmware, boot,
container-mode, and Docker-context changes are never made silently.

Setup checkpoints progress under `%LOCALAPPDATA%\AFK LocalAI\State`. After a
restart or partial failure, launch AFK LocalAI again and choose **Resume setup**
or **Try again**. Every resume starts with a fresh environment check; saved
state never overrides what Windows currently reports.

## Supported Friend Beta path

| Item | Support |
|---|---|
| Operating system | Windows 11 x64, build 22000 or newer |
| Accelerated runtime | NVIDIA GPU recommended |
| CPU-only | Supported with smaller models; substantially slower |
| Containers | Local Docker Desktop Linux-container engine |
| Windows Linux layer | Healthy WSL 2 where required by Docker Desktop |
| Model runtime | Ollama for Windows |
| Disk | About 40 GB recommended for a comfortable first setup |

Docker Hub sign-in is not required for the local stack. Models are not embedded
in the installer; setup downloads only the runtime and models selected for the
machine.

## After installation

AFK LocalAI appears in the Start Menu with shortcuts for:

- AFK LocalAI
- Diagnostics
- Data Folder
- About AFK LocalAI
- Support
- Uninstall AFK LocalAI

The application is installed per user at
`%LOCALAPPDATA%\Programs\AFK LocalAI`. User state, logs, and diagnostics live at
`%LOCALAPPDATA%\AFK LocalAI`, outside the replaceable program directory.

Open WebUI is available at `http://localhost:3000` after provisioning succeeds.
The first Open WebUI account is the local owner account; it is not an AFK cloud
account.

## Privacy and network boundary

AFK LocalAI is local-first, not permanently offline.

Local by design:

- model inference through local Ollama
- Open WebUI account and chat storage
- user-facing web services on loopback endpoints
- diagnostics intended to exclude chats, prompts, documents, and credentials

Internet access can occur for software and model downloads, updates, web
searches you enable, and integrations you choose. Ollama uses a
Docker-reachable Windows host bind so local containers can reach it; AFK
LocalAI later applies the documented firewall guardrail where supported.

## Upgrade and uninstall

Install a newer AFK LocalAI EXE normally. The stable application identity makes
Inno Setup replace program files and registration in place while preserving
`%LOCALAPPDATA%\AFK LocalAI`.

Uninstall from Windows **Installed apps** or the Start Menu. Uninstall stops the
AFK LocalAI runtime and removes the application shell, shortcuts, and uninstall
entry. It intentionally preserves user state for recovery or reinstall. See
[Install, upgrade, and uninstall](docs/install-upgrade-uninstall.md) for the
exact boundary and optional manual data removal.

## Diagnostics and support

Open **Start Menu → AFK LocalAI → Diagnostics**. AFK LocalAI creates a timestamped
report under `%LOCALAPPDATA%\AFK LocalAI\Diagnostics`, redacts the current user
profile path, and opens the folder. Review the report before attaching it to an
issue.

Never share `.env` contents, tokens, credentials, chats, prompts, documents, or
unrelated machine information. Follow [SUPPORT.md](SUPPORT.md) for a useful
Friend Beta report.

## Contributor validation

The public repository is the source of truth for the Windows distribution. The
private engineering workbench does not carry a second installer.

```powershell
python -m pip install -e ".[dev]"
pwsh -File scripts\Test-DistributionContracts.ps1
pwsh -File scripts\Build-Installer.ps1
```

Release candidates are built once on Windows, tested through clean install,
upgrade, installed self-test, and uninstall, then uploaded with a SHA-256 and
lifecycle evidence. Publishing is a separate no-rebuild workflow.

The internal Python package and CLI retain the `localai` name for compatibility.
AFK LocalAI is not affiliated with or endorsed by mudler/LocalAI or localai.io.

MIT licensed. See [LICENSE](LICENSE).
