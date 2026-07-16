# Open Design integration — design spec

Date: 2026-07-11. Approved by user in-session.

## Goal

Integrate [Open Design](https://github.com/nexu-io/open-design) (open-source,
Apache-2.0, local-first design studio; v0.14.1 at time of writing) as a
**first-class optional component** of the localai stack:

- On the user's own box (`C:\Users\jidan\localai` runs the same stack): Open
  Design generating design artifacts **driven only by the local Ollama** —
  no cloud engine.
- In the public `localai-windows-starter`: an opt-in module that installs,
  wires, verifies, and repairs Open Design the same way every other component
  is scouted, health-checked, and updated.
- The AFK-LocalAI brand (tokens from the live site's design system) shipped as
  a `DESIGN.md` preset in the public starter.

## Decisions (user calls, locked)

| Decision | Choice |
|---|---|
| Generation engine | **Local Ollama only** — no Claude Code / cloud BYOK |
| Starter shape | **Optional module** (`ai-design.ps1`), not an installer phase |
| Brand preset | **Ship AFK-LocalAI DESIGN.md in the public starter** |
| App acquisition | **Latest release, verified** — no version pin, but layered verification (below); fails closed |
| Component parity | Scouts, updates, health-checks, and self-repairs like the rest of the stack |

## Confirmed upstream facts (all verified 2026-07-11)

- **Release assets**: one Windows asset per release,
  `open-design-<ver>-win-x64-setup.exe`; the GitHub releases API publishes a
  `digest: sha256:...` per asset (confirmed on v0.14.1). No separate
  checksums file; signing status unknown until discovery.
- **Daemon**: `http://localhost:7456`; `GET /api/health`,
  `GET /api/design-systems`, `GET /api/agents`, `GET /api/skills`.
  Env: `OD_API_TOKEN`, `OD_BIND_HOST` (default localhost),
  `OD_ALLOWED_INTERNAL_HOSTS`.
- **Ollama BYOK**: first-class provider — `POST /api/proxy/ollama/stream`
  with `baseUrl` + optional `apiKey` + `model`. Secrets live in a daemon-side
  `config.toml` (0600). Exact data-dir path is deliberately undocumented
  upstream (their AGENTS.md "Daemon data directory contract") — interact via
  the daemon API, never a hardcoded path.
- **DESIGN.md**: 9 numbered sections starting "Visual Theme & Atmosphere";
  H1 = picker name; optional `> Category:` line; folder slug = id. Custom
  brands are drop-in folders discovered on refresh; installed-app location
  is a discovery item.
- **Self-updating**: the app updates in place and falls back to the full
  installer when needed (v0.14.1 release notes) — the stack must not fight it.

Sources: repo README, `docs/architecture.md`, `docs/agent-adapters.md`,
`docs/windows-troubleshooting.md`, `design-systems/README.md`, `AGENTS.md`,
releases API.

## Components

### 1. Scout: `design` category (`src/localai/scout_categories.py`)

New data row (data-driven by design — CLI/dashboard iterate CATEGORIES):

- `id="design"`, `label="Design"`, `kinds=("coder", "general")`,
  `target_ctx=32768`
- Weights modeled on `coding` (fit 1.0, kind_match 0.8, popularity 0.4,
  family 0.3, reasoning 0.3, speed 0.2)
- `curated=("qwen3-coder:30b", "qwen2.5-coder:14b")`
- `note`: honest caveat — drives Open Design artifact generation (long
  HTML/CSS/slide output); local models at 12 GB-class tiers produce working
  but not frontier-grade design artifacts.

### 2. Module: `ai-design.ps1` (repo root, starter conventions)

Dot-sources `ai-common.ps1`; plain-ASCII output; no autostart, no scheduled
tasks; loopback-only stance throughout. Modes:

- **`-Install`**:
  1. GitHub API → latest non-draft, non-prerelease release of
     `nexu-io/open-design`.
  2. Strict asset match: exactly one asset named
     `^open-design-\d+\.\d+\.\d+-win-x64-setup\.exe$`; anything else = fail
     closed.
  3. Download over TLS 1.2+; verify SHA256 against the API-published digest;
     mismatch = delete + fail closed.
  4. Authenticode check: record signer on first install into the module's
     state file (`logs/design-state.json`); on later installs compare
     (trust-on-first-use). Unsigned = surface prominently, require explicit
     `-AcceptUnsigned` to proceed.
  5. Run installer silently (NSIS `/S` — verify in discovery; if unsupported,
     interactive with a clear message).
  6. Log installed version + hash + signer to `logs/design-state.json`.
- **`-Wire`** (also runs after `-Install`): configure the Ollama BYOK
  provider — `baseUrl http://127.0.0.1:11434`, model = scout's `design` pick
  (fallback: installer chat pick from `installer-state.json`; `-Model`
  overrides). Install the AFK-LocalAI brand from
  `config/design-systems/afk-localai/DESIGN.md`. Mechanism (API vs file
  drop) fixed by discovery.
- **`-Verify`**: daemon `GET /api/health` OK on `127.0.0.1:7456`; port not
  reachable on non-loopback interfaces; brand listed in
  `/api/design-systems`; one tiny Ollama proxy round-trip.
- **`-Repair`**: re-apply wiring (provider config + brand), then `-Verify`.
- **`-Status`**: installed version, wired model, daemon state, brand present.

### 3. Health: `check_open_design()` (`src/localai/health.py`)

P1.4 precedent (WebBrain/Cherry/ComfyUI): **silent skip** when Open Design
is not installed. When installed: daemon health on loopback, loopback-only
binding, brand present. Failure detail points at `ai-design.ps1 -Repair`.

### 4. Update: MANUAL lane in `ai-update.ps1`

Same shape as the Ollama-runtime entry: compare installed version (from
design-state.json / exe metadata) against GitHub latest; **notify-only**
("Open Design self-updates in place; open the app or rerun
`ai-design.ps1 -Install`"). Never auto-reinstall over the app's own updater.

### 5. Selftest: one line in `ai-selftest.ps1`

Daemon reachable + brand listed; silent skip when absent.

### 6. Brand: `config/design-systems/afk-localai/DESIGN.md`

9-section format, authored from the site design system's real tokens:
light `#f6f8fc`/`#0a0c14` + dark `#0a0c14`/`#f0f2ff` palettes, accents
`#2563eb`/`#10b981` (dark: `#60a5fa`/`#34d399`), Inter + IBM Plex Mono,
12px radius, soft long shadows, plain/honest voice. Committed to the public
starter (tokens are already public on the live site).

### 7. README: "Optional: Open Design studio" section

What it is, the one command, the security notes: third-party Apache-2.0 app;
generation is local Ollama; nothing leaves the box; the app self-updates.

## Implementation order

**Step 0 — discovery on the user's box (before freezing module code):**
manual/module-skeleton install; find where `config.toml` + brand folder land;
test `/S` silent install; check Authenticode signer; confirm end-to-end
Ollama round-trip; A/B the chat pick vs `qwen2.5-coder:14b` on one design
prompt and set the better default. Findings get encoded in the module and
appended to this spec.

Then: scout category (+tests) → brand DESIGN.md → ai-design.ps1 →
health/selftest/update touchpoints (+tests) → README → full-suite gate →
run on the user's box end-to-end.

## Testing

- pytest baseline **269 passing** (recorded 2026-07-11, master). New units:
  design category (eligibility, weights validated against SCORE_AXES),
  `check_open_design` (skip-when-absent, OK, failure paths, mocked HTTP).
- PowerShell: release-selection/verification logic in testable functions;
  `-Verify` is the runtime gate.
- Every-phase gate: full pytest suite delta vs 269; `localai health` still
  green on a box **without** Open Design (friend-box regression check).

## Risks

- `/S` silent install undocumented upstream; may need interactive fallback.
- Installer may be unsigned (SmartScreen precedent in their docs) — TOFU
  hash+digest verification is then the only integrity layer; surfaced
  honestly in README.
- 12 GB-tier local models may be slow/mediocre on full design artifacts —
  accepted trade (local-only decision), stated in the scout note.
- Brand install mechanism (API vs folder drop) unresolved until discovery.
- No version pin = upstream regressions can reach friend boxes at install
  time (not silently afterward; the app self-updates regardless). Mitigated
  by digest verification + version logging for auditability.
