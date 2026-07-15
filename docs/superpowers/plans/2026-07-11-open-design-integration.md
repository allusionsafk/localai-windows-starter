# Open Design Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Open Design (github.com/nexu-io/open-design) as a first-class optional component of the localai stack — scouted, installed with verified downloads, health-checked, self-repairing, update-watched — generating design artifacts only via the local Ollama.

**Architecture:** Python core (`src/localai/design_studio.py`) exposing `collect_design_report(mode=...)` collectors registered as the `localai design` typer command, with a thin `ai-design.ps1` wrapper — the repo's established pattern (health, backup, scout). The scout gains a data-driven `design` category; `health.py` gains a P1.4-guarded `check_open_design`; `ai-update.ps1` gains a notify-only MANUAL lane entry. All interaction with Open Design goes through its daemon API (`http://127.0.0.1:7456`) — never hardcoded data paths, which upstream deliberately leaves undocumented.

**Tech Stack:** Python 3.12 (typer, urllib, pytest + monkeypatch), PowerShell 7 (ASCII-only output), GitHub releases API (per-asset sha256 digests), Open Design daemon REST API.

**Spec:** `docs/superpowers/specs/2026-07-11-open-design-integration-design.md`

## Global Constraints

- **Loopback only.** Every check and config uses `127.0.0.1`. Nothing may bind or point beyond loopback.
- **No autostart.** Never launch the Open Design app or daemon automatically; a stopped daemon is not a health failure (mirrors `check_image_studio`).
- **Fails closed.** Any digest mismatch, unexpected asset, or signer change aborts the install with the downloaded file deleted. Unsigned installers require explicit `--accept-unsigned`.
- **P1.4 friend-box rule.** Optional components skip **silently** in health when never installed — no WARN wall on a clean box.
- **ASCII-only PowerShell output** (PS 5.1 mangles non-ASCII in scheduled contexts).
- **pytest baseline: 269 passed** (recorded 2026-07-11 on master). Every task ends with the full suite; report the delta.
- **Commit per task; never push** (push only when the user asks).
- **Latest-release policy (user decision):** no version pin. Verification = API digest + Authenticode TOFU. Installed version always logged to `logs/design-state.json` for auditability.
- Python style: `from __future__ import annotations`, dataclasses, `collect_*_report(...) -> tuple[int, list[str]]`, tests in `tests/test_*_behavior.py`.

---

### Task 1: Discovery pass on this box (no repo code yet)

Runs on the user's machine, inline (needs the real GPU box and possibly the app GUI — do NOT dispatch to a worktree subagent). Produces a findings appendix in the spec that later tasks consume. Later tasks ship documented defaults; this task confirms or corrects them.

**Files:**
- Modify: `docs/superpowers/specs/2026-07-11-open-design-integration-design.md` (append `## Appendix A — discovery findings (Task 1)`)

**Interfaces:**
- Produces: confirmed values for `SILENT_INSTALL_ARGS` (default `('/S',)`), `DATA_DIR_CANDIDATES` (default `%APPDATA%\open-design` etc.), the BYOK proxy request body schema (default `{"baseUrl", "apiKey", "model", "messages"}`), the Authenticode signer string (or "unsigned"), and the daemon auth requirement (none vs `OD_API_TOKEN` header). Tasks 4–6 use the defaults; if discovery diverges, the executing engineer updates the named constants in Task 4–6 code before implementing them.

- [ ] **Step 1: Fetch release metadata; record tag, asset name, digest**

Run:
```powershell
$r = Invoke-RestMethod 'https://api.github.com/repos/nexu-io/open-design/releases/latest' -Headers @{ 'User-Agent' = 'localai-discovery' }
$a = $r.assets | Where-Object name -match '^open-design-[\d\.]+-win-x64-setup\.exe$'
"$($r.tag_name) | $($a.name) | $($a.digest)"
```
Expected: one line like `open-design-v0.14.1 | open-design-0.14.1-win-x64-setup.exe | sha256:18d7f5...` (exactly one asset matches).

- [ ] **Step 2: Download to the session scratchpad and verify the digest**

Run:
```powershell
$dest = Join-Path $env:TEMP $a.name
Invoke-WebRequest $a.browser_download_url -OutFile $dest
$hash = (Get-FileHash $dest -Algorithm SHA256).Hash.ToLower()
"local=$hash"; "api  =$($a.digest -replace '^sha256:','')"
```
Expected: the two hashes are identical. If not: STOP, report — do not install.

- [ ] **Step 3: Check the Authenticode signature; record the result**

Run:
```powershell
$sig = Get-AuthenticodeSignature -FilePath $dest
"$($sig.Status) | $($sig.SignerCertificate.Subject)"
```
Expected: either `Valid | CN=...` (record subject verbatim) or `NotSigned | ` (record "unsigned" — Task 6's TOFU then rests on the digest only, and the README must say so).

- [ ] **Step 4: Test silent install**

Run: `Start-Process -FilePath $dest -ArgumentList '/S' -Wait` then look for the app:
```powershell
Get-ChildItem "$env:LOCALAPPDATA\Programs" -Directory | Where-Object Name -match 'open.?design'
Get-ChildItem "$env:ProgramFiles" -Directory -ErrorAction SilentlyContinue | Where-Object Name -match 'open.?design'
```
Expected: `/S` completes without a GUI and an install dir appears (NSIS default for Electron apps). If `/S` opens the GUI instead: complete it interactively once, record "no silent install" — Task 6's installer step then prints "finish the installer window" instead of claiming silence.

- [ ] **Step 5: First launch; locate the daemon data dir**

Launch the installed app once (Start menu). After it renders, run:
```powershell
foreach ($base in @($env:APPDATA, $env:LOCALAPPDATA)) {
  Get-ChildItem $base -Directory | Where-Object Name -match 'open.?design' |
    ForEach-Object { Get-ChildItem $_.FullName -Recurse -Depth 2 -Include 'config.toml','design-systems' -ErrorAction SilentlyContinue | Select-Object FullName }
}
```
Expected: the directory containing `config.toml` (and/or a `design-systems` folder). Record it verbatim — it seeds `DATA_DIR_CANDIDATES` and gets written to `logs/design-state.json` as `dataDir` in Task 11.

- [ ] **Step 6: Probe the daemon API**

Run:
```powershell
Invoke-WebRequest 'http://127.0.0.1:7456/api/health' -UseBasicParsing | Select-Object StatusCode
(Invoke-RestMethod 'http://127.0.0.1:7456/api/design-systems') | ConvertTo-Json -Depth 3 | Select-Object -First 40
```
Expected: 200 on health; a JSON list of design systems (record the item shape — which key carries the slug/name). If 401: record "daemon requires OD_API_TOKEN" and how the desktop app provisions it.

- [ ] **Step 7: Probe the Ollama BYOK proxy round-trip**

With Ollama running (`Start Local AI.cmd` or `ollama serve`):
```powershell
$body = @{ baseUrl='http://127.0.0.1:11434'; apiKey=''; model='qwen2.5-coder:14b';
           messages=@(@{ role='user'; content='Reply with the single word: ready' }) } | ConvertTo-Json -Depth 4
Invoke-WebRequest 'http://127.0.0.1:7456/api/proxy/ollama/stream' -Method Post -Body $body -ContentType 'application/json' -UseBasicParsing -TimeoutSec 120
```
Expected: 200 and a streamed body containing "ready". Record the exact accepted body schema (rename keys if the API rejects these; check the response error message). If the endpoint needs a token, record the header name.

- [ ] **Step 8: Ollama provider in the app UI**

In the app's settings, add Ollama as provider (baseUrl `http://127.0.0.1:11434`) if a provider panel exists; record whether config lands in `config.toml` (open it — record the exact TOML block schema) or is UI-only state. **Do not** plan automated `config.toml` writes unless the block schema is confirmed here.

- [ ] **Step 9: Append findings + commit**

Append `## Appendix A — discovery findings (Task 1)` to the spec with every recorded value (tag, digest match, signer, silent-install verdict, data dir, design-systems item shape, proxy body schema, provider config location). Then:
```bash
git add docs/superpowers/specs/2026-07-11-open-design-integration-design.md
git commit -m "docs: Open Design discovery findings (Task 1)"
```

---

### Task 2: Scout `design` category

**Files:**
- Modify: `src/localai/scout_categories.py` (insert after the `coding` Category, ~line 76)
- Test: `tests/test_scout_categories_behavior.py`

**Interfaces:**
- Produces: `scout_categories.category_by_id("design")` returns a `Category` with `target_ctx=32768`, `kinds=("coder", "general")`, `curated=("qwen3-coder:30b", "qwen2.5-coder:14b")`. The scout, CLI, and dashboard pick it up automatically (they iterate `CATEGORIES`). Task 5's `resolve_design_model` reads the scout's cached `design` group.

- [ ] **Step 1: Update the exact-set test and add design tests**

In `tests/test_scout_categories_behavior.py`, change the expected set in `test_categories_are_exactly_the_brief_set`:

```python
def test_categories_are_exactly_the_brief_set() -> None:
    ids = {category.id for category in scout_categories.CATEGORIES}
    assert ids == {"chat", "coding", "design", "vision", "web-nav", "embedding", "voice"}
```

Append at the end of the file:

```python
def test_design_targets_long_artifact_context() -> None:
    # Open Design artifacts are long HTML/CSS/slide generations; the category
    # contract is 32k ctx and coder-first eligibility.
    design = scout_categories.category_by_id("design")
    assert design is not None
    assert design.target_ctx == 32768
    assert design.kinds[0] == "coder"
    assert scout_categories.weight_of(design, "kind_match") > 0


def test_design_carries_curated_seeds_and_honest_note() -> None:
    design = scout_categories.category_by_id("design")
    assert design is not None
    assert design.curated == ("qwen3-coder:30b", "qwen2.5-coder:14b")
    # The note must be honest about local-model design quality.
    assert "Open Design" in design.note
```

- [ ] **Step 2: Run to verify the new tests fail**

Run: `py -3.12 -m pytest tests/test_scout_categories_behavior.py -v`
Expected: `test_categories_are_exactly_the_brief_set`, `test_design_targets_long_artifact_context`, `test_design_carries_curated_seeds_and_honest_note` FAIL (design id missing); the rest pass.

- [ ] **Step 3: Add the Category row**

In `src/localai/scout_categories.py`, insert directly after the `coding` Category entry (keep `chat` first — a test pins the order):

```python
    Category(
        id="design",
        label="Design",
        kinds=("coder", "general"),
        target_ctx=32768,
        weights=(
            ("fit", 1.0),
            ("kind_match", 0.8),
            ("popularity", 0.4),
            ("family", 0.3),
            ("reasoning", 0.3),
            ("speed", 0.2),
        ),
        curated=("qwen3-coder:30b", "qwen2.5-coder:14b"),
        note=(
            "Drives Open Design artifact generation (long HTML/CSS/slide "
            "output) through the local BYOK proxy; 12 GB-class local models "
            "produce working but not frontier-grade design artifacts."
        ),
    ),
```

- [ ] **Step 4: Run the full suite**

Run: `py -3.12 -m pytest`
Expected: baseline 269 + 2 new = **271 passed** (the exact-set test was modified, not added). If any *other* test fails, a consumer assumed the old category set — fix that consumer, do not delete its test.

- [ ] **Step 5: Commit**

```bash
git add src/localai/scout_categories.py tests/test_scout_categories_behavior.py
git commit -m "feat(scout): design category for Open Design artifact models"
```

---

### Task 3: AFK-LocalAI brand `DESIGN.md` + format test

**Files:**
- Create: `config/design-systems/afk-localai/DESIGN.md`
- Test: `tests/test_design_studio_behavior.py` (new file; grows in Tasks 4–6)

**Interfaces:**
- Produces: the brand file at `repo_path("config", "design-systems", "afk-localai", "DESIGN.md")`. Task 6's `install_brand()` copies this folder; Task 8's health check looks for the slug `afk-localai` in the daemon's design-system list.

- [ ] **Step 1: Write the failing format test**

Create `tests/test_design_studio_behavior.py`:

```python
from __future__ import annotations

from localai.paths import repo_path

BRAND_SECTIONS = (
    "Visual Theme & Atmosphere",
    "Typography",
    "Color Palette",
    "Components",
    "Spacing",
    "Imagery",
    "Motion",
    "Voice & Tone",
    "Usage Notes",
)


def test_afk_localai_brand_matches_open_design_9_section_format() -> None:
    # Open Design parses the 9-section awesome-claude-design format; H1 names
    # the picker entry and the folder slug is the id.
    path = repo_path("config", "design-systems", "afk-localai", "DESIGN.md")
    assert path.exists(), "brand file missing"
    text = path.read_text(encoding="utf-8")
    assert text.startswith("# "), "H1 title must be first"
    for number, title in enumerate(BRAND_SECTIONS, start=1):
        assert f"## {number}. {title}" in text, f"missing section {number}. {title}"


def test_afk_localai_brand_uses_the_real_site_tokens() -> None:
    text = repo_path(
        "config", "design-systems", "afk-localai", "DESIGN.md"
    ).read_text(encoding="utf-8")
    for token in ("#2563eb", "#10b981", "#0a0c14", "IBM Plex Mono", "Inter"):
        assert token in text, f"site token {token} missing from brand"
```

- [ ] **Step 2: Run to verify it fails**

Run: `py -3.12 -m pytest tests/test_design_studio_behavior.py -v`
Expected: both FAIL with "brand file missing".

- [ ] **Step 3: Write the brand file**

Create `config/design-systems/afk-localai/DESIGN.md`:

```markdown
# AFK-LocalAI

> Category: Custom

Design system for AFK-LocalAI, the private local AI workspace for Windows.
Tokens mirror the live documentation site.

## 1. Visual Theme & Atmosphere

Calm, technical, trustworthy. A quiet documentation aesthetic: generous
whitespace, soft panels on a near-flat background, one confident accent.
Dark theme is first-class, not an afterthought. Nothing gamified, nothing
loud; the interface should read like a well-kept lab notebook.

## 2. Typography

Sans: Inter (weights 400/500/600/700/800), system-ui fallback. Mono:
IBM Plex Mono (400/500/600) for code, ports, model tags, and file paths —
any technical literal renders in mono. Body 16px, line-height 1.6. Headings
tighten to 1.2. No decorative faces.

## 3. Color Palette

Light: background #f6f8fc, panel #ffffff, panel-2 #f3f6fb, text #0a0c14,
muted #5b6980, line #dbe4f0. Dark: background #0a0c14, panel #11151f,
panel-2 #0f1420, text #f0f2ff, muted #94a3c0, line #1e2937.
Accent (primary) #2563eb (dark: #60a5fa); accent-2 (success/local)
#10b981 (dark: #34d399). Accent-2 marks "runs locally / private" states.
Both themes must pass WCAG AA for body text.

## 4. Components

Cards: 12px radius, 1px line-color border, soft long shadow
(0 10px 30px -10px, ~8% black in light, ~30% in dark). Buttons: solid
accent for the one primary action, ghost with border for everything else.
Code blocks: panel-2 background, mono, copy button top-right. Tables for
tiers/ports: minimal rules, no zebra. Status chips: small, pill-shaped,
accent-2 for OK, amber for WARN, red for FAIL.

## 5. Spacing

8px base grid. Section padding 64px desktop / 32px mobile. Card padding
24px. Never crowd: when in doubt, add one more grid step. Max content
width ~1100px, centered.

## 6. Imagery

No stock photos. Prefer terminal screenshots, real UI captures, and simple
line diagrams in the accent color. Icons: minimal stroke style, single
color, never multicolor illustration packs.

## 7. Motion

Subtle and purposeful: 150-200ms ease-out on hover/focus, no entrance
animations, no parallax. Respect prefers-reduced-motion by disabling all
transitions. Theme toggle swaps instantly.

## 8. Voice & Tone

Plain, honest, specific. Say what runs locally and what does not. Short
sentences, concrete verbs, almost no em dashes. Never oversell: "works on
a 12 GB GPU" beats "blazing fast". Security claims must be literal and
verifiable.

## 9. Usage Notes

Loopback-first: any URL shown defaults to 127.0.0.1. Dark theme must be
checked for every artifact, not assumed. Technical literals (ports, model
tags, paths) always render in mono. The one-accent rule: a screen gets one
primary button.
```

- [ ] **Step 4: Run the tests**

Run: `py -3.12 -m pytest tests/test_design_studio_behavior.py -v`
Expected: 2 passed. Then `py -3.12 -m pytest` → **273 passed**.

- [ ] **Step 5: Commit**

```bash
git add config/design-systems/afk-localai/DESIGN.md tests/test_design_studio_behavior.py
git commit -m "feat(design): AFK-LocalAI brand as Open Design 9-section DESIGN.md"
```

---

### Task 4: `design_studio.py` — release selection + digest verification

**Files:**
- Create: `src/localai/design_studio.py`
- Test: `tests/test_design_studio_behavior.py` (append)

**Interfaces:**
- Consumes: nothing from other tasks (pure functions + constants).
- Produces (Tasks 5, 6, 8 rely on these exact names):
  - `DesignStudioError(RuntimeError)`
  - `GITHUB_LATEST_URL: str`, `DAEMON_URL = "http://127.0.0.1:7456"`, `DAEMON_PORT = 7456`, `OLLAMA_BASE_URL = "http://127.0.0.1:11434"`, `BRAND_SLUG = "afk-localai"`, `SILENT_INSTALL_ARGS: tuple[str, ...] = ("/S",)`
  - `pick_release_asset(release: dict) -> dict` (raises `DesignStudioError`)
  - `parse_digest(asset: dict) -> str` (returns 64-char lowercase hex; raises)
  - `release_version(release: dict) -> str` (`open-design-v0.14.1` -> `0.14.1`)
  - `sha256_of(path: Path) -> str`

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_design_studio_behavior.py` (extend the imports at top of file):

```python
from pathlib import Path

import pytest

from localai import design_studio
from localai.design_studio import DesignStudioError


def _release(assets: list[dict], *, tag: str = "open-design-v0.14.1", **extra: object) -> dict:
    return {"tag_name": tag, "draft": False, "prerelease": False, "assets": assets, **extra}


def _asset(name: str, digest: str | None = "sha256:" + "a" * 64) -> dict:
    item: dict = {"name": name, "browser_download_url": f"https://example.invalid/{name}"}
    if digest is not None:
        item["digest"] = digest
    return item


def test_pick_release_asset_selects_the_single_windows_installer() -> None:
    win = _asset("open-design-0.14.1-win-x64-setup.exe")
    release = _release([_asset("open-design-0.14.1-mac-arm64.dmg"), win])
    assert design_studio.pick_release_asset(release) is win


def test_pick_release_asset_fails_closed_on_prerelease_and_draft() -> None:
    win = _asset("open-design-0.14.1-win-x64-setup.exe")
    with pytest.raises(DesignStudioError, match="prerelease"):
        design_studio.pick_release_asset(_release([win], prerelease=True))
    with pytest.raises(DesignStudioError, match="draft"):
        design_studio.pick_release_asset(_release([win], draft=True))


def test_pick_release_asset_fails_closed_on_zero_or_multiple_matches() -> None:
    with pytest.raises(DesignStudioError, match="expected exactly one"):
        design_studio.pick_release_asset(_release([_asset("open-design-0.14.1-mac-x64.dmg")]))
    two = [
        _asset("open-design-0.14.1-win-x64-setup.exe"),
        _asset("open-design-0.14.2-win-x64-setup.exe"),
    ]
    with pytest.raises(DesignStudioError, match="expected exactly one"):
        design_studio.pick_release_asset(_release(two))


def test_pick_release_asset_rejects_lookalike_names() -> None:
    # Strict anchor: an attacker-style near-miss must not match.
    bad = _asset("open-design-0.14.1-win-x64-setup.exe.exe")
    with pytest.raises(DesignStudioError, match="expected exactly one"):
        design_studio.pick_release_asset(_release([bad]))


def test_parse_digest_returns_lowercase_hex() -> None:
    asset = _asset("x.exe", digest="sha256:" + "AB" * 32)
    assert design_studio.parse_digest(asset) == "ab" * 32


def test_parse_digest_fails_closed_when_missing_or_malformed() -> None:
    with pytest.raises(DesignStudioError, match="digest"):
        design_studio.parse_digest(_asset("x.exe", digest=None))
    with pytest.raises(DesignStudioError, match="digest"):
        design_studio.parse_digest(_asset("x.exe", digest="md5:abcd"))
    with pytest.raises(DesignStudioError, match="digest"):
        design_studio.parse_digest(_asset("x.exe", digest="sha256:tooshort"))


def test_release_version_strips_the_tag_prefix() -> None:
    assert design_studio.release_version({"tag_name": "open-design-v0.14.1"}) == "0.14.1"
    assert design_studio.release_version({"tag_name": "v1.2.3"}) == "1.2.3"


def test_sha256_of_hashes_file_contents(tmp_path: Path) -> None:
    target = tmp_path / "blob.bin"
    target.write_bytes(b"localai")
    import hashlib

    assert design_studio.sha256_of(target) == hashlib.sha256(b"localai").hexdigest()
```

- [ ] **Step 2: Run to verify they fail**

Run: `py -3.12 -m pytest tests/test_design_studio_behavior.py -v`
Expected: new tests FAIL with `ModuleNotFoundError`/`ImportError` on `design_studio`; the two Task-3 brand tests still pass.

- [ ] **Step 3: Create the module**

Create `src/localai/design_studio.py`:

```python
"""Open Design studio integration (optional component).

Install/wire/verify/repair/status for the Open Design desktop app
(github.com/nexu-io/open-design), driven ONLY by the local Ollama. Policy
per the 2026-07-11 spec: latest release, no version pin, but layered
fails-closed verification (API sha256 digest + Authenticode trust-on-first-
use). All daemon interaction goes through its loopback REST API; upstream
deliberately leaves data paths undocumented, so we never guess them beyond
the probed candidates recorded in logs/design-state.json.
"""

from __future__ import annotations

import hashlib
import json
import re
import socket
from pathlib import Path

GITHUB_LATEST_URL = "https://api.github.com/repos/nexu-io/open-design/releases/latest"
DAEMON_URL = "http://127.0.0.1:7456"
DAEMON_PORT = 7456
OLLAMA_BASE_URL = "http://127.0.0.1:11434"
BRAND_SLUG = "afk-localai"
USER_AGENT = "localai-design-studio"
# Confirmed/adjusted by the Task-1 discovery pass (spec Appendix A).
SILENT_INSTALL_ARGS: tuple[str, ...] = ("/S",)
ASSET_PATTERN = re.compile(r"^open-design-\d+(?:\.\d+){1,3}-win-x64-setup\.exe$")
_DIGEST_PATTERN = re.compile(r"^sha256:([0-9a-fA-F]{64})$")


class DesignStudioError(RuntimeError):
    """A fails-closed condition in the Open Design integration."""


def pick_release_asset(release: dict) -> dict:
    """The single Windows installer asset of a stable release, or raise."""
    if release.get("prerelease"):
        raise DesignStudioError("latest release is a prerelease; refusing")
    if release.get("draft"):
        raise DesignStudioError("latest release is a draft; refusing")
    matches = [
        asset
        for asset in release.get("assets", [])
        if ASSET_PATTERN.match(str(asset.get("name", "")))
    ]
    if len(matches) != 1:
        names = ", ".join(str(a.get("name")) for a in release.get("assets", [])) or "none"
        raise DesignStudioError(
            f"expected exactly one win-x64 setup asset, found {len(matches)} (assets: {names})"
        )
    return matches[0]


def parse_digest(asset: dict) -> str:
    """The API-published sha256 for this asset as lowercase hex, or raise."""
    raw = str(asset.get("digest") or "")
    match = _DIGEST_PATTERN.match(raw)
    if not match:
        raise DesignStudioError(
            f"asset {asset.get('name')} has no usable sha256 digest ({raw!r}); refusing"
        )
    return match.group(1).lower()


def release_version(release: dict) -> str:
    """Tag like ``open-design-v0.14.1`` (or ``v1.2.3``) -> ``0.14.1``."""
    tag = str(release.get("tag_name", ""))
    return re.sub(r"^(open-design-)?v", "", tag)


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()
```

(`json` and `socket` are imported now because Task 5 fills in the daemon probes; if the linter flags them as unused at this commit, keep the imports minimal here and add them in Task 5 instead.)

- [ ] **Step 4: Run the tests**

Run: `py -3.12 -m pytest tests/test_design_studio_behavior.py -v`
Expected: all pass. Then `py -3.12 -m pytest` → **281 passed** (273 + 8).

- [ ] **Step 5: Lint/type gates the repo uses**

Run: `py -3.12 -m ruff check src tests` and `py -3.12 -m mypy src` (the repo has `.ruff_cache`/`.mypy_cache`, so both are in use).
Expected: clean; fix anything they flag in the new files only.

- [ ] **Step 6: Commit**

```bash
git add src/localai/design_studio.py tests/test_design_studio_behavior.py
git commit -m "feat(design): fails-closed release selection + digest verification"
```

---

### Task 5: `design_studio.py` — state, model resolution, daemon probes, verify/status

**Files:**
- Modify: `src/localai/design_studio.py`
- Test: `tests/test_design_studio_behavior.py` (append)

**Interfaces:**
- Consumes: Task 4 constants/helpers; `localai.model_scout.read_scout_groups()` (returns `{"generated": ..., "groups": {cid: {"top": {"id": "curated/<tag>", "curated": bool, ...}}}}` or `None`); `localai.perf.read_default_model()` (returns `str`, "" when unknown).
- Produces (Tasks 6 and 8 rely on these exact names):
  - `state_path() -> Path` (= `repo_path("logs", "design-state.json")`)
  - `load_state() -> dict`, `save_state(state: dict) -> None`
  - `resolve_design_model(override: str | None) -> tuple[str, str]` — `(model_tag, source_label)`
  - `daemon_ok(*, timeout_sec: float = 3) -> bool`
  - `daemon_design_systems(*, timeout_sec: float = 5) -> list[str]` (lowercased slugs/names; `[]` on any error)
  - `daemon_reachable_beyond_loopback(*, timeout_sec: float = 1) -> list[str]` (offending IPs)
  - `proxy_roundtrip(model: str, *, timeout_sec: float = 120) -> tuple[bool, str]`
  - `collect_design_verify_report(*, model: str | None = None, timeout_sec: int = 120) -> tuple[int, list[str]]`
  - `collect_design_status_report() -> tuple[int, list[str]]`

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_design_studio_behavior.py`:

```python
def test_state_round_trips_and_survives_corruption(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    state_file = tmp_path / "design-state.json"
    monkeypatch.setattr(design_studio, "state_path", lambda: state_file)
    assert design_studio.load_state() == {}
    design_studio.save_state({"installedVersion": "0.14.1"})
    assert design_studio.load_state() == {"installedVersion": "0.14.1"}
    state_file.write_text("{not json", encoding="utf-8")
    assert design_studio.load_state() == {}


def test_resolve_design_model_override_wins(monkeypatch: pytest.MonkeyPatch) -> None:
    model, source = design_studio.resolve_design_model("my-model:tag")
    assert model == "my-model:tag"
    assert source == "override"


def test_resolve_design_model_uses_curated_scout_pick(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    groups = {
        "generated": "2026-07-11 12:00",
        "groups": {
            "design": {"top": {"id": "curated/qwen3-coder:30b", "curated": True}}
        },
    }
    monkeypatch.setattr(design_studio, "read_scout_groups", lambda: groups)
    model, source = design_studio.resolve_design_model(None)
    assert model == "qwen3-coder:30b"
    assert source == "scout design pick"


def test_resolve_design_model_falls_back_to_webui_default(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # A non-curated scout top is an HF repo id, not a pullable Ollama tag;
    # fall through to the Open WebUI default, then to the curated seed.
    monkeypatch.setattr(design_studio, "read_scout_groups", lambda: None)
    monkeypatch.setattr(design_studio, "read_default_model", lambda: "qwen3.5:9b-32k")
    model, source = design_studio.resolve_design_model(None)
    assert model == "qwen3.5:9b-32k"
    assert source == "Open WebUI default"
    monkeypatch.setattr(design_studio, "read_default_model", lambda: "")
    model, source = design_studio.resolve_design_model(None)
    assert model == "qwen2.5-coder:14b"
    assert source == "curated fallback"


def test_verify_report_fails_when_daemon_down(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(design_studio, "_tcp_open", lambda *a, **k: False)
    monkeypatch.setattr(design_studio, "daemon_ok", lambda **k: False)
    code, lines = design_studio.collect_design_verify_report(model="m:1")
    assert code == 1
    joined = "\n".join(lines)
    assert "daemon not running" in joined
    assert "no autostart" in joined


def test_verify_report_green_path(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(design_studio, "daemon_ok", lambda **k: True)
    monkeypatch.setattr(
        design_studio, "daemon_design_systems", lambda **k: ["afk-localai", "stripe"]
    )
    monkeypatch.setattr(
        design_studio, "daemon_reachable_beyond_loopback", lambda **k: []
    )
    monkeypatch.setattr(design_studio, "_tcp_open", lambda *a, **k: True)
    monkeypatch.setattr(
        design_studio, "proxy_roundtrip", lambda model, **k: (True, "ready in 2.1s")
    )
    code, lines = design_studio.collect_design_verify_report(model="m:1")
    assert code == 0
    joined = "\n".join(lines)
    assert "[OK]" in joined and "[FAIL]" not in joined


def test_verify_report_fails_on_non_loopback_exposure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(design_studio, "daemon_ok", lambda **k: True)
    monkeypatch.setattr(design_studio, "daemon_design_systems", lambda **k: ["afk-localai"])
    monkeypatch.setattr(
        design_studio, "daemon_reachable_beyond_loopback", lambda **k: ["192.168.1.20"]
    )
    monkeypatch.setattr(design_studio, "_tcp_open", lambda *a, **k: True)
    monkeypatch.setattr(design_studio, "proxy_roundtrip", lambda m, **k: (True, "ok"))
    code, lines = design_studio.collect_design_verify_report(model="m:1")
    assert code == 1
    assert any("192.168.1.20" in line for line in lines)


def test_status_report_never_fails_and_shows_install_state(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(design_studio, "state_path", lambda: tmp_path / "s.json")
    monkeypatch.setattr(design_studio, "daemon_ok", lambda **k: False)
    monkeypatch.setattr(design_studio, "read_scout_groups", lambda: None)
    monkeypatch.setattr(design_studio, "read_default_model", lambda: "")
    code, lines = design_studio.collect_design_status_report()
    assert code == 0
    joined = "\n".join(lines)
    assert "not installed" in joined
```

- [ ] **Step 2: Run to verify they fail**

Run: `py -3.12 -m pytest tests/test_design_studio_behavior.py -v`
Expected: the new tests FAIL (`AttributeError` on the missing functions); Task 3–4 tests pass.

- [ ] **Step 3: Implement**

Append to `src/localai/design_studio.py` (extend the imports at the top of the file with the ones shown):

```python
from urllib.error import URLError
from urllib.request import Request, urlopen

from localai.model_scout import read_scout_groups
from localai.paths import repo_path
from localai.perf import read_default_model

# --------------------------------------------------------------- state ----


def state_path() -> Path:
    return repo_path("logs", "design-state.json")


def load_state() -> dict:
    path = state_path()
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def save_state(state: dict) -> None:
    path = state_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, indent=2), encoding="utf-8")


# ------------------------------------------------------ model resolution --


def resolve_design_model(override: str | None) -> tuple[str, str]:
    """The Ollama tag design runs should use, and where the pick came from.

    Order: explicit override > the scout's curated design pick (a curated
    top IS a pullable tag; an HF-repo top is not, so it is skipped) > the
    Open WebUI default model > the category's first curated seed.
    """
    if override:
        return override, "override"
    payload = read_scout_groups()
    groups = payload.get("groups") if isinstance(payload, dict) else None
    design = groups.get("design") if isinstance(groups, dict) else None
    top = design.get("top") if isinstance(design, dict) else None
    if isinstance(top, dict) and top.get("curated"):
        identifier = str(top.get("id", ""))
        if "/" in identifier:
            return identifier.split("/", 1)[1], "scout design pick"
    default = read_default_model()
    if default:
        return default, "Open WebUI default"
    return "qwen2.5-coder:14b", "curated fallback"


# ------------------------------------------------------- daemon probing ---
# Self-contained network helpers (health.py imports this module; importing
# health from here would be a cycle).


def _tcp_open(host: str, port: int, *, timeout_sec: float) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout_sec):
            return True
    except OSError:
        return False


def _request_json(url: str, *, timeout_sec: float, method: str = "GET", body: bytes | None = None) -> object:
    request = Request(
        url,
        data=body,
        method=method,
        headers={"User-Agent": USER_AGENT, "Content-Type": "application/json"},
    )
    with urlopen(request, timeout=timeout_sec) as response:
        return json.loads(response.read().decode("utf-8"))


def daemon_ok(*, timeout_sec: float = 3) -> bool:
    try:
        request = Request(f"{DAEMON_URL}/api/health", headers={"User-Agent": USER_AGENT})
        with urlopen(request, timeout=timeout_sec) as response:
            return int(response.status) == 200
    except (OSError, URLError, ValueError):
        return False


def daemon_design_systems(*, timeout_sec: float = 5) -> list[str]:
    """Lowercased ids/slugs/names the daemon reports; [] on any error."""
    try:
        payload = _request_json(f"{DAEMON_URL}/api/design-systems", timeout_sec=timeout_sec)
    except (OSError, URLError, ValueError, json.JSONDecodeError):
        return []
    items = payload if isinstance(payload, list) else []
    names: list[str] = []
    for item in items:
        if isinstance(item, str):
            names.append(item.lower())
        elif isinstance(item, dict):
            for key in ("id", "slug", "name", "title"):
                value = item.get(key)
                if isinstance(value, str):
                    names.append(value.lower())
    return names


def daemon_reachable_beyond_loopback(*, timeout_sec: float = 1) -> list[str]:
    """Non-loopback local IPs where the daemon port answers (should be [])."""
    offenders: list[str] = []
    try:
        host_ips = {
            info[4][0]
            for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET)
        }
    except OSError:
        return []
    for ip in sorted(host_ips):
        if ip.startswith("127."):
            continue
        if _tcp_open(ip, DAEMON_PORT, timeout_sec=timeout_sec):
            offenders.append(ip)
    return offenders


def proxy_roundtrip(model: str, *, timeout_sec: float = 120) -> tuple[bool, str]:
    """One tiny generation through the daemon's Ollama BYOK proxy.

    Body schema per docs + Task-1 discovery: baseUrl/apiKey/model/messages.
    """
    body = json.dumps(
        {
            "baseUrl": OLLAMA_BASE_URL,
            "apiKey": "",
            "model": model,
            "messages": [
                {"role": "user", "content": "Reply with the single word: ready"}
            ],
        }
    ).encode("utf-8")
    request = Request(
        f"{DAEMON_URL}/api/proxy/ollama/stream",
        data=body,
        method="POST",
        headers={"User-Agent": USER_AGENT, "Content-Type": "application/json"},
    )
    try:
        with urlopen(request, timeout=timeout_sec) as response:
            status = int(response.status)
            preview = response.read(2048).decode("utf-8", errors="replace")
    except URLError as exc:
        reason = getattr(exc, "code", None) or getattr(exc, "reason", exc)
        if reason in (401, 403):
            return False, (
                f"daemon rejected the proxy call ({reason}); it may require its "
                "OD_API_TOKEN - open the app settings and retry"
            )
        return False, f"proxy call failed: {reason}"
    except (OSError, ValueError) as exc:
        return False, f"proxy call failed: {exc}"
    if status != 200:
        return False, f"proxy returned HTTP {status}"
    return True, f"model {model} answered through the daemon proxy ({preview[:60]!r}...)"


# ---------------------------------------------------------- collectors ----


def _status_line(status: str, name: str, detail: str) -> str:
    return f"[{status}] {name:<24} {detail}"


def collect_design_verify_report(
    *, model: str | None = None, timeout_sec: int = 120
) -> tuple[int, list[str]]:
    """Gate: daemon healthy + loopback-only + brand present + Ollama round-trip."""
    lines: list[str] = ["==== localai design verify ===="]
    failed = False
    resolved, source = resolve_design_model(model)
    lines.append(_status_line("OK", "Design model", f"{resolved} ({source})"))

    if not _tcp_open("127.0.0.1", 11434, timeout_sec=2):
        failed = True
        lines.append(
            _status_line("FAIL", "Ollama", "not reachable on 127.0.0.1:11434 - run Start Local AI")
        )

    if not daemon_ok(timeout_sec=3):
        failed = True
        lines.append(
            _status_line(
                "FAIL",
                "Open Design daemon",
                "daemon not running on 127.0.0.1:7456 - open the Open Design app "
                "(no autostart by design), then rerun verify",
            )
        )
        lines.append("")
        lines.append("Summary: verify FAILED")
        return 1, lines
    lines.append(_status_line("OK", "Open Design daemon", "healthy on 127.0.0.1:7456"))

    offenders = daemon_reachable_beyond_loopback(timeout_sec=1)
    if offenders:
        failed = True
        lines.append(
            _status_line(
                "FAIL",
                "Loopback binding",
                f"daemon answers on non-loopback {', '.join(offenders)} - set "
                "OD_BIND_HOST=127.0.0.1 and restart the app",
            )
        )
    else:
        lines.append(_status_line("OK", "Loopback binding", "port 7456 loopback-only"))

    systems = daemon_design_systems(timeout_sec=5)
    if BRAND_SLUG in systems:
        lines.append(_status_line("OK", "AFK-LocalAI brand", "listed by the daemon"))
    else:
        failed = True
        lines.append(
            _status_line(
                "FAIL",
                "AFK-LocalAI brand",
                "not listed - run ai-design.ps1 -Repair, then refresh the app",
            )
        )

    ok, detail = proxy_roundtrip(resolved, timeout_sec=timeout_sec)
    lines.append(_status_line("OK" if ok else "FAIL", "Ollama proxy round-trip", detail))
    failed = failed or not ok

    lines.append("")
    lines.append("Summary: verify " + ("FAILED" if failed else "OK"))
    return (1 if failed else 0), lines


def collect_design_status_report() -> tuple[int, list[str]]:
    """Read-only snapshot; never a failing exit code."""
    lines: list[str] = ["==== localai design status ===="]
    state = load_state()
    version = str(state.get("installedVersion") or "")
    if version:
        signer = str(state.get("signer") or "unsigned")
        lines.append(_status_line("OK", "Installed", f"v{version} (signer: {signer})"))
    else:
        lines.append(
            _status_line("OK", "Installed", "not installed - run ai-design.ps1 -Install")
        )
    if daemon_ok(timeout_sec=2):
        systems = daemon_design_systems(timeout_sec=5)
        brand = "present" if BRAND_SLUG in systems else "missing (run -Repair)"
        lines.append(_status_line("OK", "Daemon", "running; brand " + brand))
    else:
        lines.append(
            _status_line("OK", "Daemon", "not running (manual start; no autostart by design)")
        )
    resolved, source = resolve_design_model(None)
    lines.append(_status_line("OK", "Design model", f"{resolved} ({source})"))
    return 0, lines
```

- [ ] **Step 4: Run the tests**

Run: `py -3.12 -m pytest tests/test_design_studio_behavior.py -v`
Expected: all pass. Full suite: `py -3.12 -m pytest` → **289 passed** (281 + 8).

- [ ] **Step 5: Lint + commit**

Run `py -3.12 -m ruff check src tests` and `py -3.12 -m mypy src`; fix new-file findings.

```bash
git add src/localai/design_studio.py tests/test_design_studio_behavior.py
git commit -m "feat(design): daemon probes, model resolution, verify/status collectors"
```

---

### Task 6: `design_studio.py` — install/wire/repair, dispatcher, CLI command

**Files:**
- Modify: `src/localai/design_studio.py`
- Modify: `src/localai/cli.py` (import + one command)
- Test: `tests/test_design_studio_behavior.py` (append)

**Interfaces:**
- Consumes: Tasks 4–5 helpers; `localai.ops.run_command` (`run_command(args, *, cwd=None, env=None, timeout_sec=None) -> CommandResult` with `.code`, `.text`).
- Produces:
  - `authenticode_signer(path: Path) -> str | None` (`None` = unsigned/undeterminable)
  - `download_file(url: str, dest: Path, *, timeout_sec: float) -> None`
  - `fetch_latest_release(*, timeout_sec: float = 30) -> dict`
  - `data_dir_candidates() -> tuple[Path, ...]`, `find_data_dir() -> Path | None`
  - `install_brand() -> tuple[bool, str]`
  - `collect_design_install_report(*, model: str | None = None, accept_unsigned: bool = False, timeout_sec: int = 1800) -> tuple[int, list[str]]`
  - `collect_design_wire_report(*, model: str | None = None, timeout_sec: int = 120) -> tuple[int, list[str]]`
  - `collect_design_repair_report(*, model: str | None = None, timeout_sec: int = 120) -> tuple[int, list[str]]`
  - `collect_design_report(mode: str, *, model: str | None = None, accept_unsigned: bool = False, timeout_sec: int = 1800) -> tuple[int, list[str]]`
  - CLI: `localai design {install|wire|verify|repair|status} [--model TAG] [--accept-unsigned] [--timeout-sec N]`

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_design_studio_behavior.py`:

```python
def _install_fixture(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> dict:
    """Wire every side effect of install to fakes; return a mutable log."""
    log: dict = {"installed": False}
    release = _release(
        [_asset("open-design-0.14.1-win-x64-setup.exe", digest="sha256:" + "a" * 64)]
    )
    monkeypatch.setattr(design_studio, "state_path", lambda: tmp_path / "state.json")
    monkeypatch.setattr(design_studio, "fetch_latest_release", lambda **k: release)

    def fake_download(url: str, dest: Path, *, timeout_sec: float) -> None:
        dest.write_bytes(b"installer-bytes")

    monkeypatch.setattr(design_studio, "download_file", fake_download)
    monkeypatch.setattr(design_studio, "sha256_of", lambda path: "a" * 64)
    monkeypatch.setattr(design_studio, "authenticode_signer", lambda path: "CN=Nexu")

    def fake_run_installer(path: Path, *, timeout_sec: float) -> tuple[bool, str]:
        log["installed"] = True
        return True, "silent install ok"

    monkeypatch.setattr(design_studio, "_run_installer", fake_run_installer)
    monkeypatch.setattr(
        design_studio, "collect_design_wire_report", lambda **k: (0, ["wire ok"])
    )
    monkeypatch.setattr(design_studio, "_download_dir", lambda: tmp_path)
    return log


def test_install_happy_path_records_state(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    log = _install_fixture(monkeypatch, tmp_path)
    code, lines = design_studio.collect_design_install_report()
    assert code == 0
    assert log["installed"] is True
    state = design_studio.load_state()
    assert state["installedVersion"] == "0.14.1"
    assert state["sha256"] == "a" * 64
    assert state["signer"] == "CN=Nexu"


def test_install_fails_closed_on_digest_mismatch(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    log = _install_fixture(monkeypatch, tmp_path)
    monkeypatch.setattr(design_studio, "sha256_of", lambda path: "b" * 64)
    code, lines = design_studio.collect_design_install_report()
    assert code == 1
    assert log["installed"] is False
    assert not (tmp_path / "open-design-0.14.1-win-x64-setup.exe").exists(), (
        "mismatched download must be deleted"
    )


def test_install_blocks_unsigned_without_opt_in(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    log = _install_fixture(monkeypatch, tmp_path)
    monkeypatch.setattr(design_studio, "authenticode_signer", lambda path: None)
    code, lines = design_studio.collect_design_install_report()
    assert code == 1
    assert log["installed"] is False
    assert any("--accept-unsigned" in line or "-AcceptUnsigned" in line for line in lines)
    code, _ = design_studio.collect_design_install_report(accept_unsigned=True)
    assert code == 0


def test_install_fails_closed_when_signer_changes(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    log = _install_fixture(monkeypatch, tmp_path)
    design_studio.save_state({"signer": "CN=Someone Else"})
    code, lines = design_studio.collect_design_install_report()
    assert code == 1
    assert log["installed"] is False
    assert any("signer changed" in line for line in lines)


def test_wire_installs_brand_and_reports_roundtrip(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(design_studio, "state_path", lambda: tmp_path / "state.json")
    monkeypatch.setattr(design_studio, "install_brand", lambda: (True, "brand copied"))
    monkeypatch.setattr(design_studio, "daemon_ok", lambda **k: True)
    monkeypatch.setattr(design_studio, "proxy_roundtrip", lambda m, **k: (True, "ok"))
    code, lines = design_studio.collect_design_wire_report(model="m:1")
    assert code == 0


def test_wire_daemon_down_gives_manual_steps_not_failure(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # Wiring with the app closed is expected on first run; it must guide,
    # not fail (verify is the strict gate).
    monkeypatch.setattr(design_studio, "state_path", lambda: tmp_path / "state.json")
    monkeypatch.setattr(design_studio, "install_brand", lambda: (True, "brand copied"))
    monkeypatch.setattr(design_studio, "daemon_ok", lambda **k: False)
    code, lines = design_studio.collect_design_wire_report(model="m:1")
    assert code == 0
    joined = "\n".join(lines)
    assert "http://127.0.0.1:11434" in joined  # the settings to paste in the app


def test_find_data_dir_prefers_recorded_state(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    recorded = tmp_path / "od-data"
    recorded.mkdir()
    monkeypatch.setattr(design_studio, "state_path", lambda: tmp_path / "state.json")
    design_studio.save_state({"dataDir": str(recorded)})
    assert design_studio.find_data_dir() == recorded


def test_collect_design_report_dispatches_and_rejects_unknown_mode() -> None:
    code, lines = design_studio.collect_design_report("bogus")
    assert code == 2
    assert any("install | wire | verify | repair | status" in line for line in lines)
```

- [ ] **Step 2: Run to verify they fail**

Run: `py -3.12 -m pytest tests/test_design_studio_behavior.py -v`
Expected: new tests FAIL (missing attributes); earlier tests pass.

- [ ] **Step 3: Implement**

Append to `src/localai/design_studio.py` (add `import os`, `import shutil`, `import tempfile` to the imports; also `from localai.ops import run_command`):

```python
# ------------------------------------------------------------ install -----


def fetch_latest_release(*, timeout_sec: float = 30) -> dict:
    payload = _request_json(GITHUB_LATEST_URL, timeout_sec=timeout_sec)
    if not isinstance(payload, dict):
        raise DesignStudioError("releases API returned an unexpected payload")
    return payload


def _download_dir() -> Path:
    return Path(tempfile.gettempdir())


def download_file(url: str, dest: Path, *, timeout_sec: float) -> None:
    request = Request(url, headers={"User-Agent": USER_AGENT})
    with urlopen(request, timeout=timeout_sec) as response, dest.open("wb") as handle:
        shutil.copyfileobj(response, handle, length=1024 * 1024)


def authenticode_signer(path: Path) -> str | None:
    """Signer subject when the file has a Valid signature, else None."""
    script = (
        f"$s = Get-AuthenticodeSignature -FilePath '{path}'; "
        "Write-Output ($s.Status.ToString() + '|' + "
        "[string]$s.SignerCertificate.Subject)"
    )
    result = run_command(
        ["powershell", "-NoProfile", "-Command", script], timeout_sec=60
    )
    if result.code != 0 or "|" not in result.text:
        return None
    status, _, subject = result.text.strip().partition("|")
    if status.strip() != "Valid" or not subject.strip():
        return None
    return subject.strip()


def _run_installer(path: Path, *, timeout_sec: float) -> tuple[bool, str]:
    # NSIS silent switch, confirmed by the Task-1 discovery pass. If that
    # pass found no silent mode, this still works: the GUI opens and the
    # user finishes it; run_command waits for the process to exit.
    result = run_command([str(path), *SILENT_INSTALL_ARGS], timeout_sec=timeout_sec)
    if result.code != 0:
        return False, f"installer exited {result.code}: {result.text.strip()[:200]}"
    return True, "installer completed"


def collect_design_install_report(
    *, model: str | None = None, accept_unsigned: bool = False, timeout_sec: int = 1800
) -> tuple[int, list[str]]:
    """Verified latest-release install, then wire. Fails closed everywhere."""
    lines: list[str] = ["==== localai design install ===="]
    try:
        release = fetch_latest_release()
        asset = pick_release_asset(release)
        expected = parse_digest(asset)
        version = release_version(release)
    except (DesignStudioError, OSError, URLError, ValueError) as exc:
        lines.append(_status_line("FAIL", "Release lookup", str(exc)))
        return 1, lines
    lines.append(_status_line("OK", "Release", f"v{version} ({asset['name']})"))

    dest = _download_dir() / str(asset["name"])
    try:
        download_file(str(asset["browser_download_url"]), dest, timeout_sec=timeout_sec)
    except (OSError, URLError) as exc:
        lines.append(_status_line("FAIL", "Download", str(exc)))
        return 1, lines

    actual = sha256_of(dest)
    if actual != expected:
        dest.unlink(missing_ok=True)
        lines.append(
            _status_line(
                "FAIL",
                "SHA256 verify",
                f"digest mismatch (expected {expected[:12]}..., got {actual[:12]}...); "
                "download deleted - refusing to install",
            )
        )
        return 1, lines
    lines.append(_status_line("OK", "SHA256 verify", f"matches API digest {expected[:12]}..."))

    signer = authenticode_signer(dest)
    state = load_state()
    known_signer = str(state.get("signer") or "")
    if signer is None and not accept_unsigned:
        dest.unlink(missing_ok=True)
        lines.append(
            _status_line(
                "FAIL",
                "Authenticode",
                "installer is not validly signed. The sha256 digest DID match the "
                "GitHub API. If you accept that as sufficient, rerun with "
                "--accept-unsigned (ai-design.ps1 -Install -AcceptUnsigned).",
            )
        )
        return 1, lines
    if signer and known_signer and known_signer != "unsigned" and signer != known_signer:
        dest.unlink(missing_ok=True)
        lines.append(
            _status_line(
                "FAIL",
                "Authenticode",
                f"signer changed since first install ({known_signer} -> {signer}); "
                "refusing - investigate upstream before reinstalling",
            )
        )
        return 1, lines
    lines.append(_status_line("OK", "Authenticode", signer or "unsigned (accepted by flag)"))

    ok, detail = _run_installer(dest, timeout_sec=timeout_sec)
    if not ok:
        lines.append(_status_line("FAIL", "Install", detail))
        return 1, lines
    lines.append(_status_line("OK", "Install", detail))

    state.update(
        {
            "installedVersion": version,
            "sha256": actual,
            "signer": signer or "unsigned",
            "assetName": str(asset["name"]),
        }
    )
    save_state(state)

    wire_code, wire_lines = collect_design_wire_report(model=model, timeout_sec=120)
    lines.extend(wire_lines)
    return wire_code, lines


# --------------------------------------------------------------- wire -----


def data_dir_candidates() -> tuple[Path, ...]:
    # Seeded from the Task-1 discovery pass; find_data_dir prefers the dir
    # recorded in design-state.json over these guesses.
    bases = [os.environ.get("APPDATA", ""), os.environ.get("LOCALAPPDATA", "")]
    names = ("open-design", "OpenDesign", "Open Design")
    return tuple(Path(base) / name for base in bases if base for name in names)


def find_data_dir() -> Path | None:
    state = load_state()
    recorded = str(state.get("dataDir") or "")
    if recorded and Path(recorded).is_dir():
        return Path(recorded)
    for candidate in data_dir_candidates():
        if candidate.is_dir():
            state["dataDir"] = str(candidate)
            save_state(state)
            return candidate
    return None


def install_brand() -> tuple[bool, str]:
    """Copy the repo's AFK-LocalAI DESIGN.md into the daemon's data dir."""
    source = repo_path("config", "design-systems", BRAND_SLUG, "DESIGN.md")
    if not source.exists():
        return False, f"repo brand file missing: {source}"
    data_dir = find_data_dir()
    if data_dir is None:
        return False, (
            "Open Design data dir not found - open the app once so it creates "
            "its data folder, then rerun ai-design.ps1 -Repair"
        )
    target = data_dir / "design-systems" / BRAND_SLUG / "DESIGN.md"
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    return True, f"brand copied to {target}"


def collect_design_wire_report(
    *, model: str | None = None, timeout_sec: int = 120
) -> tuple[int, list[str]]:
    """Brand + provider wiring. Guides rather than fails when the app is closed."""
    lines: list[str] = ["==== localai design wire ===="]
    resolved, source = resolve_design_model(model)
    lines.append(_status_line("OK", "Design model", f"{resolved} ({source})"))

    ok, detail = install_brand()
    lines.append(_status_line("OK" if ok else "WARN", "AFK-LocalAI brand", detail))

    if daemon_ok(timeout_sec=3):
        proxy_ok, proxy_detail = proxy_roundtrip(resolved, timeout_sec=timeout_sec)
        lines.append(
            _status_line("OK" if proxy_ok else "WARN", "Ollama proxy", proxy_detail)
        )
        if not proxy_ok:
            lines.append(
                "    In the Open Design app: Settings -> add the Ollama provider with"
            )
            lines.append(f"    baseUrl http://127.0.0.1:11434 and model {resolved}.")
    else:
        lines.append(
            _status_line(
                "OK",
                "Daemon",
                "not running (no autostart by design). When you open the app, add "
                "the Ollama provider:",
            )
        )
        lines.append(f"    baseUrl  http://127.0.0.1:11434   model  {resolved}")
        lines.append("    Then run: ai-design.ps1 -Verify")
    return 0, lines


def collect_design_repair_report(
    *, model: str | None = None, timeout_sec: int = 120
) -> tuple[int, list[str]]:
    """Re-apply wiring, then run the strict verify gate."""
    code, lines = collect_design_wire_report(model=model, timeout_sec=timeout_sec)
    verify_code, verify_lines = collect_design_verify_report(
        model=model, timeout_sec=timeout_sec
    )
    return max(code, verify_code), [*lines, "", *verify_lines]


# ---------------------------------------------------------- dispatcher ----


def collect_design_report(
    mode: str,
    *,
    model: str | None = None,
    accept_unsigned: bool = False,
    timeout_sec: int = 1800,
) -> tuple[int, list[str]]:
    normalized = mode.strip().lower()
    if normalized == "install":
        return collect_design_install_report(
            model=model, accept_unsigned=accept_unsigned, timeout_sec=timeout_sec
        )
    if normalized == "wire":
        return collect_design_wire_report(model=model, timeout_sec=min(timeout_sec, 300))
    if normalized == "verify":
        return collect_design_verify_report(model=model, timeout_sec=min(timeout_sec, 300))
    if normalized == "repair":
        return collect_design_repair_report(model=model, timeout_sec=min(timeout_sec, 300))
    if normalized == "status":
        return collect_design_status_report()
    return 2, [f"unknown mode {mode!r}: use install | wire | verify | repair | status"]
```

- [ ] **Step 4: Register the CLI command**

In `src/localai/cli.py`, add to the imports:

```python
from localai.design_studio import collect_design_report
```

Add this command (alphabetical placement beside the others is fine):

```python
@app.command()
def design(
    mode: Annotated[
        str,
        typer.Argument(help="install | wire | verify | repair | status"),
    ] = "status",
    model: Annotated[
        str,
        typer.Option("--model", help="Ollama model tag override for design runs."),
    ] = "",
    accept_unsigned: Annotated[
        bool,
        typer.Option(
            "--accept-unsigned",
            help="Install even when the setup exe has no valid Authenticode "
            "signature (the sha256 digest is still enforced).",
        ),
    ] = False,
    timeout_sec: Annotated[
        int,
        typer.Option("--timeout-sec", help="Seconds for downloads/installs.", min=30, max=7200),
    ] = 1800,
) -> None:
    """Open Design studio (optional): install, wire to Ollama, verify, repair."""
    code, lines = collect_design_report(
        mode,
        model=model or None,
        accept_unsigned=accept_unsigned,
        timeout_sec=timeout_sec,
    )
    for line in lines:
        typer.echo(line)
    raise typer.Exit(code=code)
```

- [ ] **Step 5: Run the tests + CLI smoke**

Run: `py -3.12 -m pytest tests/test_design_studio_behavior.py -v` → all pass.
Run: `py -3.12 -m pytest` → **297 passed** (289 + 8).
Run: `py -3.12 -m localai design status`
Expected: a status card ending exit 0 (works even with nothing installed).
Run: `py -3.12 -m localai design bogus; echo $LASTEXITCODE`
Expected: usage line, exit 2.

- [ ] **Step 6: Lint + commit**

Run `py -3.12 -m ruff check src tests` and `py -3.12 -m mypy src`; fix new findings.

```bash
git add src/localai/design_studio.py src/localai/cli.py tests/test_design_studio_behavior.py
git commit -m "feat(design): verified install, wire/repair collectors, localai design CLI"
```

---

### Task 7: `ai-design.ps1` thin wrapper

**Files:**
- Create: `ai-design.ps1` (repo root, beside the other `ai-*.ps1`)

**Interfaces:**
- Consumes: `Invoke-AiLocalai([string[]]$Arguments, [int]$TimeoutSec, [string]$WorkingDirectory)` from `ai-common.ps1`; the `localai design` command from Task 6.
- Produces: the user-facing module the README, health check, and update lane all name.

- [ ] **Step 1: Write the wrapper**

Create `ai-design.ps1`:

```powershell
#requires -Version 7.0
<#
  ai-design.ps1 - Open Design studio (OPTIONAL component).

  Installs and wires the open-source Open Design desktop app
  (github.com/nexu-io/open-design, Apache-2.0) so its design generation runs
  ONLY against the local Ollama at 127.0.0.1:11434. Thin wrapper over
  `localai design` (src/localai/design_studio.py) - logic and tests live there.

  Modes:
    Install : fetch the LATEST release, verify sha256 against the GitHub API
              digest + Authenticode (fails closed), run the installer, wire.
    Wire    : install the AFK-LocalAI brand + point design runs at the local
              Ollama (scout design pick, or -Model).
    Verify  : strict gate - daemon healthy, loopback-only, brand present,
              one real Ollama round-trip.
    Repair  : re-apply wiring, then Verify.
    Status  : (default) read-only snapshot.

  Security stance: loopback-only, no autostart, no scheduled tasks. The app
  self-updates in place; ai-update.ps1 only notifies about new versions.
  ASCII-only output on purpose.
#>
[CmdletBinding()]
param(
  [ValidateSet('Install','Wire','Verify','Repair','Status')]
  [string]$Mode = 'Status',
  [string]$Model,
  [switch]$AcceptUnsigned,
  [ValidateRange(30, 7200)]
  [int]$TimeoutSec = 1800
)

$Root = $PSScriptRoot
. (Join-Path $Root 'ai-common.ps1')

$cliArgs = @('design', $Mode.ToLower())
if ($Model)          { $cliArgs += @('--model', $Model) }
if ($AcceptUnsigned) { $cliArgs += '--accept-unsigned' }
$cliArgs += @('--timeout-sec', "$TimeoutSec")

$r = Invoke-AiLocalai $cliArgs ($TimeoutSec + 60) $Root
if ($r.Text) { Write-Host $r.Text }
exit $r.Code
```

- [ ] **Step 2: Behavior smoke**

Run: `pwsh -ExecutionPolicy Bypass -File ai-design.ps1` (defaults to Status)
Expected: the same status card as `py -3.12 -m localai design status`, exit 0.
Run: `pwsh -ExecutionPolicy Bypass -File ai-design.ps1 -Mode Bogus`
Expected: PowerShell parameter validation error (ValidateSet), non-zero exit.

- [ ] **Step 3: Commit**

```bash
git add ai-design.ps1
git commit -m "feat(design): ai-design.ps1 wrapper for the localai design command"
```

---

### Task 8: Health check + selftest line

**Files:**
- Modify: `src/localai/health.py` (new `check_open_design`, registered in `collect_health_report` after `check_image_studio(add_line)`)
- Modify: `ai-selftest.ps1` (one optional block near the other service checks)
- Test: `tests/test_health_behavior.py` (append)

**Interfaces:**
- Consumes: `design_studio.load_state()`, `design_studio.daemon_ok()`, `design_studio.daemon_design_systems()`, `design_studio.BRAND_SLUG` (Task 5). `health.py` imports `design_studio`; design_studio must NOT import health (cycle — its probes are self-contained by design).
- Produces: `check_open_design(add_line: AddLine) -> None` in the standard health report.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_health_behavior.py`:

```python
def test_health_open_design_silently_skips_when_never_installed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from localai import design_studio

    lines: list[tuple[str, str, str]] = []
    monkeypatch.setattr(design_studio, "load_state", lambda: {})
    monkeypatch.setattr(design_studio, "daemon_ok", lambda **k: False)
    health.check_open_design(lambda s, n, d: lines.append((s, n, d)))
    # P1.4: opt-in extra absent on a friend box -> no line at all.
    assert lines == []


def test_health_open_design_installed_but_stopped_is_ok(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from localai import design_studio

    lines: list[tuple[str, str, str]] = []
    monkeypatch.setattr(
        design_studio, "load_state", lambda: {"installedVersion": "0.14.1"}
    )
    monkeypatch.setattr(design_studio, "daemon_ok", lambda **k: False)
    health.check_open_design(lambda s, n, d: lines.append((s, n, d)))
    assert lines == [
        (
            "OK",
            "Open Design",
            "v0.14.1 installed; daemon not running (manual start by design)",
        )
    ]


def test_health_open_design_running_with_brand_is_ok(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from localai import design_studio

    lines: list[tuple[str, str, str]] = []
    monkeypatch.setattr(design_studio, "load_state", lambda: {})
    monkeypatch.setattr(design_studio, "daemon_ok", lambda **k: True)
    monkeypatch.setattr(
        design_studio, "daemon_design_systems", lambda **k: ["afk-localai"]
    )
    health.check_open_design(lambda s, n, d: lines.append((s, n, d)))
    assert lines == [
        ("OK", "Open Design", "daemon healthy on 127.0.0.1:7456; AFK-LocalAI brand loaded")
    ]


def test_health_open_design_running_without_brand_warns(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from localai import design_studio

    lines: list[tuple[str, str, str]] = []
    monkeypatch.setattr(design_studio, "load_state", lambda: {})
    monkeypatch.setattr(design_studio, "daemon_ok", lambda **k: True)
    monkeypatch.setattr(design_studio, "daemon_design_systems", lambda **k: ["stripe"])
    health.check_open_design(lambda s, n, d: lines.append((s, n, d)))
    assert lines == [
        (
            "WARN",
            "Open Design",
            "daemon healthy but AFK-LocalAI brand missing - run ai-design.ps1 -Repair",
        )
    ]
```

- [ ] **Step 2: Run to verify they fail**

Run: `py -3.12 -m pytest tests/test_health_behavior.py -v`
Expected: 4 new FAIL (`AttributeError: check_open_design`); existing pass.

- [ ] **Step 3: Implement the check**

In `src/localai/health.py`, add `from localai import design_studio` to the imports, add the function next to `check_image_studio`:

```python
def check_open_design(add_line: AddLine) -> None:
    # Optional extra (P1.4): a box that never installed Open Design gets no
    # line at all; a stopped daemon on an installed box is the no-autostart
    # contract working, not a failure.
    daemon_up = design_studio.daemon_ok(timeout_sec=2)
    if not daemon_up:
        version = str(design_studio.load_state().get("installedVersion") or "")
        if version:
            add_line(
                "OK",
                "Open Design",
                f"v{version} installed; daemon not running (manual start by design)",
            )
        return
    systems = design_studio.daemon_design_systems(timeout_sec=5)
    if design_studio.BRAND_SLUG in systems:
        add_line(
            "OK",
            "Open Design",
            "daemon healthy on 127.0.0.1:7456; AFK-LocalAI brand loaded",
        )
    else:
        add_line(
            "WARN",
            "Open Design",
            "daemon healthy but AFK-LocalAI brand missing - run ai-design.ps1 -Repair",
        )
```

Register it in `collect_health_report` directly after `check_image_studio(add_line)`:

```python
    check_image_studio(add_line)
    check_open_design(add_line)
```

- [ ] **Step 4: Run the tests**

Run: `py -3.12 -m pytest tests/test_health_behavior.py -v` → all pass.
Run: `py -3.12 -m pytest` → **301 passed** (297 + 4).

- [ ] **Step 5: Add the selftest line**

In `ai-selftest.ps1`, after the existing optional service checks (find the SearXNG/Kokoro/image blocks; append alongside them):

```powershell
# Open Design studio (optional) - silent skip when never installed
$designStatePath = Join-Path $Root 'logs\design-state.json'
$odUp = $false
try {
  $odUp = (Invoke-WebRequest 'http://127.0.0.1:7456/api/health' -UseBasicParsing -TimeoutSec 3).StatusCode -eq 200
} catch { }
if ($odUp) {
  Line 'OK' 'Open Design' 'daemon healthy on 127.0.0.1:7456'
} elseif (Test-Path $designStatePath) {
  Line 'WARN' 'Open Design' 'installed but not running - open the app if you want to test it (no autostart by design)'
}
```

Run: `pwsh -ExecutionPolicy Bypass -File ai-selftest.ps1 -SkipWeb -SkipVision -SkipCode -SkipApplyEdit -NoWarm`
Expected: suite runs; on a box without `logs/design-state.json` and no daemon, NO "Open Design" line appears (silent skip).

- [ ] **Step 6: Commit**

```bash
git add src/localai/health.py tests/test_health_behavior.py ai-selftest.ps1
git commit -m "feat(design): P1.4-guarded Open Design health check + selftest line"
```

---

### Task 9: `ai-update.ps1` MANUAL lane entry

**Files:**
- Modify: `ai-update.ps1` (in the `DETECT: risky / notify` section, directly after the Kokoro block that ends near line 258)

**Interfaces:**
- Consumes: existing `$Manual` list, `Say`, `Note`, `Test-Newer` (which strips a leading `v` but NOT the `open-design-` prefix — strip it explicitly), `logs/design-state.json` from Task 6.
- Produces: a notify-only "Open Design" manual item, deduped across weeks by the existing `manualNotified` state.

- [ ] **Step 1: Add the detection block**

Insert after the Kokoro check block:

```powershell
  # Open Design (optional; the app self-updates in place - notify only)
  $designStatePath = Join-Path $LogDir 'design-state.json'
  if (Test-Path $designStatePath) {
    Say "[*] Checking Open Design (optional)..." 'Cyan'
    try {
      $ds = Get-Content $designStatePath -Raw | ConvertFrom-Json
      $curOd = [string]$ds.installedVersion
      if ($curOd) {
        $latestOdTag = (Invoke-RestMethod 'https://api.github.com/repos/nexu-io/open-design/releases/latest' -Headers @{ 'User-Agent' = 'localai-updater' } -TimeoutSec 20).tag_name
        $latestOd = $latestOdTag -replace '^open-design-v', ''
        if (Test-Newer $curOd $latestOd) {
          $Manual.Add([pscustomobject]@{ name='Open Design'; key='open-design'; cur=$curOd; latest=$latestOd;
            how='Open Design self-updates in place when you open the app. To force a verified reinstall: pwsh -File ai-design.ps1 -Install, then ai-design.ps1 -Verify.' })
          Say "    $latestOd available (you have $curOd)" 'Yellow'
        } else { Say "    up to date ($curOd)" 'DarkGray' }
      }
    } catch { Note "could not check Open Design releases (offline?)." }
  }
```

- [ ] **Step 2: Smoke it in Check mode**

Run: `pwsh -ExecutionPolicy Bypass -File ai-update.ps1 -Mode Check -Quiet`
Expected: on a box WITHOUT `logs/design-state.json`, no "Open Design" line at all (skip). On the user's box after Task 11: either "up to date (x.y.z)" or a Manual item in `logs/update-log.md`. Exit 0 either way.

- [ ] **Step 3: Commit**

```bash
git add ai-update.ps1
git commit -m "feat(design): notify-only Open Design lane in the weekly updater"
```

---

### Task 10: README section + full gate

**Files:**
- Modify: `README.md` (new section after the existing optional-extras content; match the README's plain, honest voice)

**Interfaces:**
- Consumes: everything shipped in Tasks 2–9.

- [ ] **Step 1: Add the README section**

Add (placement: with the other optional components; keep heading level consistent with siblings):

```markdown
## Optional: Open Design studio

[Open Design](https://github.com/nexu-io/open-design) is an open-source
(Apache-2.0) desktop app that turns a model into a design engine: prototypes,
landing pages, dashboards, slides. This kit can wire it so generation runs
**only against your local Ollama** - nothing leaves your PC.

```powershell
pwsh -ExecutionPolicy Bypass -File ai-design.ps1 -Install
```

What that does, in order: fetches the latest release from GitHub, verifies
the download's SHA256 against the digest GitHub publishes for that exact
file (a mismatch deletes the file and stops), checks the installer's code
signature, runs the installer, copies in the AFK-LocalAI design preset, and
points design runs at `http://127.0.0.1:11434` using the model the scout
picked for the `design` category (override with `-Model <tag>`).

Honest notes:

- Open Design is a third-party app with its own in-place self-updater; the
  weekly updater here only *tells* you when a new version exists.
- If the installer is not code-signed, the install stops and says so; rerun
  with `-AcceptUnsigned` if the SHA256 match is enough for you.
- Design generation quality tracks your GPU tier. A 12 GB-class model
  produces working drafts, not agency work.
- Like everything else here: loopback-only, no autostart. `ai-design.ps1
  -Verify` proves the daemon is loopback-bound and the local round-trip
  works; `ai-design.ps1 -Repair` re-applies the wiring.
```

- [ ] **Step 2: Full gate**

Run: `py -3.12 -m pytest`
Expected: **301 passed** (269 baseline + 32 new across Tasks 2–8; report the actual delta and name any failure).
Run: `py -3.12 -m localai health`
Expected: on this box (Open Design possibly installed by Task 1) the Open Design line is OK; the summary has no new FAIL versus a pre-task run.
Run the repo lint/type gates one more time: `py -3.12 -m ruff check src tests`, `py -3.12 -m mypy src`.

- [ ] **Step 3: Friend-box regression check (the P1.4 gate)**

Temporarily rename the state file if it exists (`Rename-Item logs\design-state.json design-state.json.bak`), stop the Open Design app, run `py -3.12 -m localai health`:
Expected: NO "Open Design" line at all. Restore the state file afterwards.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: Open Design studio section - honest install + security notes"
```

---

### Task 11: End-to-end on this box (the user's machine)

Run inline on the real box — this is the runtime gate the whole feature hangs on. Requires: Ollama running, Open Design installed (Task 1 did it; `-Install` re-verifies).

**Files:**
- Modify: `docs/superpowers/specs/2026-07-11-open-design-integration-design.md` (append `## Appendix B — end-to-end results (Task 11)`)

- [ ] **Step 1: Full module pass**

Run in order, recording each exit code:
```powershell
pwsh -ExecutionPolicy Bypass -File ai-design.ps1 -Status
pwsh -ExecutionPolicy Bypass -File ai-design.ps1 -Repair
pwsh -ExecutionPolicy Bypass -File ai-design.ps1 -Verify
```
Expected: Status exit 0; Repair exit 0 with brand copied; Verify exit 0 with all OK lines (daemon healthy, loopback-only, brand listed, round-trip answered). If Verify fails on the round-trip, fix per its own detail line (token/provider) before proceeding — do not skip.

- [ ] **Step 2: A/B the design model (scout pick vs daily driver)**

In the Open Design app, generate the SAME one-page artifact twice ("a landing page for a local-first AI starter kit, dark theme") — once with the scout design pick (e.g. `qwen2.5-coder:14b`), once with the chat daily driver. Judge: does it render, is the HTML valid, wall-clock time. Set the winner as the box default: `pwsh -File ai-design.ps1 -Wire -Model <winner>`.

- [ ] **Step 3: Brand smoke**

In the app's design-system picker, select **AFK-LocalAI** and regenerate. Expected: artifact uses the dark `#0a0c14` background family and mono for technical literals.

- [ ] **Step 4: Scout + health + updater on the real box**

```powershell
py -3.12 -m localai scout --help   # confirm the design category is listed/usable per existing scout CLI flags
py -3.12 -m localai health
pwsh -ExecutionPolicy Bypass -File ai-update.ps1 -Mode Check -Quiet
```
Expected: health shows the Open Design OK line; updater shows "up to date (<version>)" or a manual item; nothing regressed elsewhere in health versus before this feature.

- [ ] **Step 5: Record + commit**

Append Appendix B to the spec: exit codes from Step 1, A/B result + chosen model, brand smoke verdict, health/updater output lines. Then:
```bash
git add docs/superpowers/specs/2026-07-11-open-design-integration-design.md
git commit -m "docs: Open Design end-to-end results on the reference box (Task 11)"
```

---

## Plan-level verification summary

| Gate | Where | Expected |
|---|---|---|
| pytest full suite | every task | 269 -> 271 -> 273 -> 281 -> 289 -> 297 -> 301, no unrelated failures |
| ruff + mypy | Tasks 4, 5, 6, 10 | clean on new/changed files |
| Friend-box silence | Task 10 Step 3 | no Open Design line without state file + daemon |
| Runtime gate | Task 11 | `ai-design.ps1 -Verify` exit 0 on the real box |
| Update lane | Tasks 9, 11 | notify-only; correct version compare with prefix stripped |

Out of scope (name-and-leave, per spec): automated edits to Open Design's `config.toml` (UI-only unless Task 1 proved a safe schema), the private `localai` repo's in-flight scout branch, any release/tag/push of this repo.
