"""Updater check mode ported from ai-update.ps1."""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any
from urllib.error import URLError
from urllib.request import Request, urlopen

from localai.backup import collect_backup_report
from localai.model_aliases import collect_model_aliases_report
from localai.ops import CommandResult, run_command
from localai.paths import REPO_ROOT, repo_path

OPEN_WEBUI_IMAGE = "ghcr.io/open-webui/open-webui:main"
IMAGE_PRUNE_TIMEOUT_SEC = 300
MODEL_PULL_TIMEOUT_SEC = 3600
MODEL_CREATE_TIMEOUT_SEC = 1800


@dataclass(frozen=True)
class ApplyWrapper:
    grounded: str
    file: str


@dataclass(frozen=True)
class ApplyModel:
    base: str
    wrappers: tuple[ApplyWrapper, ...]


# Mirrors the $models table in ai-update.ps1 -Mode Apply: base model + the
# grounded wrapper(s) rebuilt from a Modelfile when the base changes or the
# wrapper is missing. Qwen3.6-35B feeds two wrappers.
APPLY_MODELS: tuple[ApplyModel, ...] = (
    ApplyModel(
        "qwen2.5:14b",
        (ApplyWrapper("qwen2.5-grounded", "qwen-grounded.Modelfile"),),
    ),
    ApplyModel(
        "hf.co/unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF:UD-Q4_K_XL",
        (ApplyWrapper("qwen3-grounded", "qwen3-grounded.Modelfile"),),
    ),
    ApplyModel(
        "hf.co/unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q3_K_XL",
        (
            ApplyWrapper("qwen3.6-35b-a3b-grounded", "scout-qwen3.6-35b-a3b.Modelfile"),
            ApplyWrapper(
                "qwen3.6-thinklight-grounded",
                "qwen3.6-thinklight-grounded.Modelfile",
            ),
        ),
    ),
    ApplyModel("qwen2.5-coder:14b", ()),
    ApplyModel("qwen3-coder:30b", ()),
    ApplyModel("qwen2.5vl:7b", ()),
    ApplyModel("nomic-embed-text", ()),
)


@dataclass(frozen=True)
class ManualItem:
    name: str
    key: str
    current: str
    latest: str
    how: str


@dataclass
class UpdateState:
    manual_notified: dict[str, str]
    last_apply_seconds: int = 0
    last_check: str = ""


def collect_update_report(
    *,
    mode: str = "Check",
    quiet: bool = False,
    dry_run: bool = False,
    now: datetime | None = None,
    probe_timeout_sec: int = 60,
    docker_timeout_sec: int = 1800,
) -> tuple[int, list[str]]:
    """Run update check or the safe apply path."""
    elapsed_start = datetime.now()
    normalized_mode = normalize_mode(mode)
    if normalized_mode not in {"Check", "Apply", "Auto"}:
        return 2, [f"[!] Unknown update mode: {mode}"]
    if normalized_mode == "Auto":
        return 2, ["localai update --mode Auto is not ported to Python yet."]
    if normalized_mode == "Apply":
        return collect_update_apply_report(
            dry_run=dry_run,
            now=now,
            docker_timeout_sec=docker_timeout_sec,
        )

    run_start = now or datetime.now()
    lines = [
        "",
        f"==== localai updater ====  mode: {normalized_mode}   "
        f"{run_start.strftime('%Y-%m-%d %H:%M')}",
    ]
    notes: list[str] = []
    manual: list[ManualItem] = []

    docker_up = docker_running(timeout_sec=probe_timeout_sec)
    if not docker_up:
        note(notes, lines, "Docker is not running - skipping container checks/updates.")

    compose_text = read_compose_text()
    searxng_tag = read_image_tag(compose_text, r"searxng/searxng:([^\s\"']+)")
    kokoro_tag = read_image_tag(compose_text, r"kokoro-fastapi-cpu:([^\s\"']+)")

    # DETECT: safe (Open WebUI image, local-vs-remote registry digest).
    ow_status = "skipped (Docker not running)"
    if docker_up:
        lines.append("[*] Checking Open WebUI image...")
        ow_local = get_image_local_digest(
            OPEN_WEBUI_IMAGE, timeout_sec=probe_timeout_sec
        )
        ow_remote = get_image_remote_digest(
            OPEN_WEBUI_IMAGE, timeout_sec=probe_timeout_sec
        )
        if ow_remote and ow_local and ow_remote != ow_local:
            lines.append("    update available")
            ow_status = "update available"
        elif not ow_remote:
            note(
                notes,
                lines,
                "could not reach registry for Open WebUI - "
                "will refresh on apply anyway.",
            )
            ow_status = "registry unreachable; will refresh on apply"
        else:
            lines.append("    up to date")
            ow_status = "up to date"

    ollama = ollama_path()
    if ollama.exists():
        lines.append("[*] Checking Ollama runtime...")
        try:
            current = current_ollama_version(ollama, timeout_sec=probe_timeout_sec)
            latest = latest_github_release("ollama/ollama")
            if is_newer(current, latest):
                manual.append(
                    ManualItem(
                        name="Ollama runtime",
                        key="ollama",
                        current=current,
                        latest=latest,
                        how=(
                            "Ollama self-updates; or get it from "
                            "https://ollama.com/download , then restart Ollama."
                        ),
                    )
                )
                lines.append(f"    {latest} available (you have {current})")
            else:
                lines.append(f"    up to date ({current})")
        except (OSError, TimeoutError, URLError, json.JSONDecodeError, RuntimeError):
            note(notes, lines, "could not check Ollama releases (offline?).")
    else:
        note(
            notes,
            lines,
            f"Ollama not found at {ollama} - skipping model checks/updates.",
        )

    # DETECT: notify-only (SearXNG + Kokoro are pinned on purpose in compose).
    if docker_up and searxng_tag != "unknown":
        lines.append("[*] Checking SearXNG (pinned)...")
        try:
            payload = http_get_json(
                "https://hub.docker.com/v2/repositories/searxng/searxng/tags"
                "?page_size=25&ordering=last_updated",
                timeout_sec=20,
            )
            names = (
                [str(row.get("name", "")) for row in payload.get("results", [])]
                if isinstance(payload, dict)
                else []
            )
            newest = next(
                (name for name in names if re.match(r"^\d{4}\.\d+\.\d+", name)),
                None,
            )
            if newest and searxng_has_newer(
                searxng_tag, newest, timeout_sec=probe_timeout_sec
            ):
                manual.append(
                    ManualItem(
                        name="SearXNG",
                        key="searxng",
                        current=searxng_tag,
                        latest=newest,
                        how=(
                            "PINNED on purpose (newer tags have broken the boot). "
                            "Only if you will test it: edit docker-compose.yml searxng "
                            "image tag, then run the updater, then confirm "
                            "http://localhost:8080 loads."
                        ),
                    )
                )
                lines.append(f"    {newest} available (pinned at {searxng_tag})")
            else:
                lines.append(f"    no newer tag (pinned at {searxng_tag})")
        except (OSError, TimeoutError, URLError, json.JSONDecodeError):
            note(notes, lines, "could not check SearXNG tags (offline?).")

    if docker_up and kokoro_tag != "unknown":
        lines.append("[*] Checking Kokoro TTS (pinned)...")
        try:
            latest_kokoro = latest_github_release("remsky/Kokoro-FastAPI")
            if is_newer(kokoro_tag, latest_kokoro):
                manual.append(
                    ManualItem(
                        name="Kokoro TTS",
                        key="kokoro",
                        current=kokoro_tag,
                        latest=latest_kokoro,
                        how=(
                            "PINNED. To update: edit docker-compose.yml kokoro image "
                            "tag to this version, run the updater, then test voice "
                            "playback in a chat."
                        ),
                    )
                )
                lines.append(f"    {latest_kokoro} available (pinned at {kokoro_tag})")
            else:
                lines.append(f"    up to date ({kokoro_tag})")
        except (OSError, TimeoutError, URLError, json.JSONDecodeError, RuntimeError):
            note(notes, lines, "could not check Kokoro releases (offline?).")

    state = load_state()
    new_manual = update_manual_notifications(state, manual)
    state.last_check = run_start.isoformat()
    save_state(state)
    write_update_log(
        mode=normalized_mode,
        now=run_start,
        notes=notes,
        manual=manual,
        new_manual=new_manual,
        ow_status=ow_status,
    )

    elapsed = max(0, round((datetime.now() - elapsed_start).total_seconds()))
    lines.append("")
    lines.append(f"[OK] Done in {elapsed}s. Log: logs\\update-log.md")
    if manual:
        lines.append(f"[i] {len(manual)} manual update(s) to review in the log.")
    return 0, lines


def collect_update_apply_report(
    *,
    dry_run: bool = False,
    now: datetime | None = None,
    docker_timeout_sec: int = 1800,
) -> tuple[int, list[str]]:
    """Apply safe updates: backup, Docker refresh, and model alias refresh."""
    elapsed_start = datetime.now()
    run_start = now or datetime.now()
    lines = [
        "",
        "==== localai updater ====  mode: Apply   "
        f"{run_start.strftime('%Y-%m-%d %H:%M')}",
    ]
    failures = 0

    if dry_run:
        lines.extend(
            [
                "[dry-run] No backup, containers, images, models, or model "
                "aliases will be changed.",
                "[+] Backing up Open WebUI data...",
                "    would run: localai backup",
                "[+] Refreshing Docker images and containers...",
                "    would run: docker compose pull",
                "    would run: docker compose up -d",
                "    would run: docker image prune -f",
                "[+] Refreshing Ollama models (incremental)...",
                f"    would run: ollama pull x{len(APPLY_MODELS)} bases, "
                "rebuild grounded wrappers if changed",
                "[+] Refreshing purpose-based model aliases...",
                "    would run: localai model-aliases",
                "",
                "[OK] Apply dry-run complete. Log: logs\\update-log.md",
            ]
        )
        write_update_log(
            mode="Apply",
            now=run_start,
            notes=["dry-run apply preview; nothing changed"],
            manual=[],
            new_manual=[],
            ow_status="dry-run apply preview",
        )
        return 0, lines

    docker_ok = False
    lines.append("[+] Backing up Open WebUI data...")
    backup_code, backup_lines = collect_backup_report(timeout_sec=900)
    lines.extend(prefix_lines(backup_lines))
    if backup_code != 0:
        failures += 1
        lines.append("    backup failed; skipping Docker update.")
    else:
        lines.append("[+] Refreshing Docker images and containers...")
        pull = run_command(
            ["docker", "compose", "pull"],
            cwd=REPO_ROOT,
            timeout_sec=docker_timeout_sec,
        )
        lines.extend(command_summary_lines("docker compose pull", pull))
        up = run_command(
            ["docker", "compose", "up", "-d"],
            cwd=REPO_ROOT,
            timeout_sec=docker_timeout_sec,
        )
        lines.extend(command_summary_lines("docker compose up -d", up))
        prune = run_command(
            ["docker", "image", "prune", "-f"],
            cwd=REPO_ROOT,
            timeout_sec=IMAGE_PRUNE_TIMEOUT_SEC,
        )
        lines.extend(command_summary_lines("docker image prune", prune))
        if pull.code != 0 or up.code != 0 or prune.code != 0:
            failures += 1
        else:
            docker_ok = True

    ollama = ollama_path()
    if docker_ok and ollama.exists():
        lines.append("[+] Refreshing Ollama models (incremental)...")
        for model in APPLY_MODELS:
            failures += apply_one_model(ollama, model, lines)
    elif docker_ok:
        lines.append(f"    Ollama not found at {ollama}; skipping model refresh.")

    lines.append("[+] Refreshing purpose-based model aliases...")
    alias_code, alias_lines = collect_model_aliases_report()
    lines.extend(prefix_lines(alias_lines))
    if alias_code != 0:
        failures += 1

    state = load_state()
    elapsed = max(0, round((datetime.now() - elapsed_start).total_seconds()))
    state.last_apply_seconds = elapsed
    state.last_check = run_start.isoformat()
    save_state(state)
    write_update_log(
        mode="Apply",
        now=run_start,
        notes=(["Apply failed or was skipped before completion."] if failures else []),
        manual=[],
        new_manual=[],
        ow_status=("apply failed or skipped" if failures else "applied safe updates"),
    )

    lines.append("")
    if failures:
        lines.append("[FAIL] Apply failed or was skipped. Log: logs\\update-log.md")
        return 2, lines
    lines.append("[OK] Apply complete. Log: logs\\update-log.md")
    return 0, lines


def prefix_lines(lines: list[str]) -> list[str]:
    return [f"    {line}" if line else "" for line in lines]


def command_summary_lines(label: str, result: CommandResult) -> list[str]:
    text = result.text.strip()
    if result.code == 0:
        return [f"    {label}: OK" + (f" - {last_nonblank_line(text)}" if text else "")]
    return [f"    {label}: FAILED", *prefix_lines(text.splitlines())]


def last_nonblank_line(text: str) -> str:
    for line in reversed(text.splitlines()):
        stripped = line.strip()
        if stripped:
            return stripped
    return ""


def get_ollama_id(ollama: Path, name: str) -> str:
    """Return the Ollama model id for a name, mirroring ai-update.ps1 Get-OllamaId."""
    result = run_command([str(ollama), "list"], cwd=REPO_ROOT, timeout_sec=30)
    if result.code != 0:
        return ""
    want = name.lower()
    for line in result.text.splitlines()[1:]:
        cols = re.split(r"\s{2,}", line.strip())
        if len(cols) < 2:
            continue
        if cols[0].lower() in (want, f"{want}:latest"):
            return cols[1].strip()
    return ""


def apply_one_model(ollama: Path, model: ApplyModel, lines: list[str]) -> int:
    """Pull a base model and rebuild grounded wrappers if it changed/is missing."""
    failures = 0
    pre = get_ollama_id(ollama, model.base)
    lines.append(f"    pull {model.base}")
    pull = run_command(
        [str(ollama), "pull", model.base],
        cwd=REPO_ROOT,
        timeout_sec=MODEL_PULL_TIMEOUT_SEC,
    )
    if pull.code != 0:
        lines.append(
            f"    model pull failed for {model.base} (exit {pull.code}); "
            "skipping wrapper rebuild."
        )
        return 1
    post = get_ollama_id(ollama, model.base)
    changed = pre != post
    if changed:
        lines.append(f"    model {model.base}: {pre} -> {post}")
    for wrapper in model.wrappers:
        grounded_exists = bool(get_ollama_id(ollama, wrapper.grounded))
        if not (changed or not grounded_exists):
            continue
        modelfile = repo_path(wrapper.file)
        if not modelfile.exists():
            lines.append(
                f"    missing {wrapper.file} - cannot rebuild {wrapper.grounded}."
            )
            continue
        lines.append(f"    rebuild {wrapper.grounded}")
        create = run_command(
            [str(ollama), "create", wrapper.grounded, "-f", str(modelfile)],
            cwd=REPO_ROOT,
            timeout_sec=MODEL_CREATE_TIMEOUT_SEC,
        )
        if create.code != 0:
            lines.append(
                f"    rebuild failed for {wrapper.grounded} "
                f"(exit {create.code}). {create.text.strip()}"
            )
            failures += 1
    return failures


def normalize_mode(mode: str) -> str:
    return mode[:1].upper() + mode[1:].lower() if mode else mode


def note(notes: list[str], lines: list[str], message: str) -> None:
    notes.append(message)
    lines.append(f"    {message}")


def ollama_path() -> Path:
    local_app_data = os.environ.get("LOCALAPPDATA", "")
    return Path(local_app_data) / "Programs" / "Ollama" / "ollama.exe"


def read_compose_text() -> str:
    try:
        return repo_path("docker-compose.yml").read_text(encoding="utf-8")
    except OSError:
        return ""


def read_image_tag(compose_text: str, pattern: str) -> str:
    match = re.search(pattern, compose_text)
    return match.group(1) if match else "unknown"


def docker_running(*, timeout_sec: int) -> bool:
    result = run_command(
        ["docker", "info", "--format", "{{.ServerVersion}}"],
        cwd=REPO_ROOT,
        timeout_sec=timeout_sec,
    )
    return result.code == 0


def current_ollama_version(ollama: Path, *, timeout_sec: int) -> str:
    result = run_command(
        [str(ollama), "--version"],
        cwd=REPO_ROOT,
        timeout_sec=timeout_sec,
    )
    if result.code != 0:
        raise RuntimeError(result.text.strip())
    match = re.search(r"\d+\.\d+\.\d+", result.text)
    return match.group(0) if match else ""


def get_image_local_digest(ref: str, *, timeout_sec: int) -> str | None:
    """Local image digest, mirroring ai-update.ps1 Get-ImageLocalDigest."""
    result = run_command(
        ["docker", "image", "inspect", ref, "--format", "{{index .RepoDigests 0}}"],
        cwd=REPO_ROOT,
        timeout_sec=timeout_sec,
    )
    if result.code != 0 or not result.text.strip():
        return None
    first = result.text.strip().splitlines()[0]
    return first.split("@")[-1].strip()


def get_image_remote_digest(ref: str, *, timeout_sec: int) -> str | None:
    """Remote registry digest, mirroring ai-update.ps1 Get-ImageRemoteDigest."""
    result = run_command(
        [
            "docker",
            "buildx",
            "imagetools",
            "inspect",
            ref,
            "--format",
            "{{.Manifest.Digest}}",
        ],
        cwd=REPO_ROOT,
        timeout_sec=timeout_sec,
    )
    if result.code == 0 and result.text.strip():
        return result.text.strip().splitlines()[0].strip()
    return None


def http_get_json(url: str, *, timeout_sec: int) -> Any:
    request = Request(url, headers={"User-Agent": "localai-updater"})
    with urlopen(request, timeout=timeout_sec) as response:
        return json.loads(response.read().decode("utf-8"))


def latest_github_release(repo: str) -> str:
    payload = http_get_json(
        f"https://api.github.com/repos/{repo}/releases/latest", timeout_sec=20
    )
    if not isinstance(payload, dict) or not payload.get("tag_name"):
        raise RuntimeError("release response did not include tag_name")
    return str(payload["tag_name"])


def is_newer(current: str, latest: str) -> bool:
    current_version = parse_version(current)
    latest_version = parse_version(latest)
    if current_version and latest_version:
        return latest_version > current_version
    return bool(latest and current and latest != current)


def parse_version(value: str) -> tuple[int, ...] | None:
    match = re.match(r"^[vV]?(\d+(?:\.\d+){0,3})", value.strip())
    if not match:
        return None
    return tuple(int(part) for part in match.group(1).split("."))


def searxng_date_key(tag: str) -> tuple[int, int, int] | None:
    match = re.match(r"^(\d{4})\.(\d+)\.(\d+)", tag)
    if not match:
        return None
    return (int(match.group(1)), int(match.group(2)), int(match.group(3)))


def searxng_has_newer(
    current_tag: str, candidate_tag: str, *, timeout_sec: int = 60
) -> bool:
    """True if candidate is a newer SearXNG build than current.

    SearXNG tags are date+build (e.g. 2026.6.22-952896d29); parse_version drops
    the build suffix, so two same-date builds compare equal. Compare by date
    prefix first (never flag an older tag), then by registry digest so a newer
    same-date build is detected. Fall back to notifying on any differing
    newer-or-equal-date tag when digests cannot be compared (notify-only).
    """
    if candidate_tag == current_tag:
        return False
    current_date = searxng_date_key(current_tag)
    candidate_date = searxng_date_key(candidate_tag)
    if current_date and candidate_date and candidate_date < current_date:
        return False
    image = "docker.io/searxng/searxng"
    current_digest = get_image_remote_digest(
        f"{image}:{current_tag}", timeout_sec=timeout_sec
    )
    candidate_digest = get_image_remote_digest(
        f"{image}:{candidate_tag}", timeout_sec=timeout_sec
    )
    if current_digest and candidate_digest:
        return current_digest != candidate_digest
    return True


def load_state() -> UpdateState:
    path = repo_path("logs", "state.json")
    if not path.exists():
        return UpdateState(manual_notified={})
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return UpdateState(manual_notified={})
    if not isinstance(payload, dict):
        return UpdateState(manual_notified={})
    manual = payload.get("manualNotified")
    return UpdateState(
        manual_notified=dict(manual) if isinstance(manual, dict) else {},
        last_apply_seconds=int(payload.get("lastApplySeconds") or 0),
        last_check=str(payload.get("lastCheck") or ""),
    )


def save_state(state: UpdateState) -> None:
    path = repo_path("logs", "state.json")
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "manualNotified": state.manual_notified,
        "lastApplySeconds": state.last_apply_seconds,
        "lastCheck": state.last_check,
    }
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def update_manual_notifications(
    state: UpdateState,
    manual: list[ManualItem],
) -> list[ManualItem]:
    new_manual = []
    for item in manual:
        if state.manual_notified.get(item.key) != item.latest:
            new_manual.append(item)
        state.manual_notified[item.key] = item.latest
    return new_manual


def write_update_log(
    *,
    mode: str,
    now: datetime,
    notes: list[str],
    manual: list[ManualItem],
    new_manual: list[ManualItem],
    ow_status: str,
) -> None:
    path = repo_path("logs", "update-log.md")
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [f"## {now.strftime('%Y-%m-%d %H:%M')}  (mode: {mode})"]
    lines.append("- Check only - nothing was changed.")
    lines.append(f"- Open WebUI: {ow_status}.")
    if manual:
        lines.append("**Manual (notify-only):**")
        for item in manual:
            tag = "NEW" if item in new_manual else "seen"
            lines.append(
                f"- [{tag}] {item.name}: {item.latest} available "
                f"(you have {item.current}). {item.how}"
            )
    for message in notes:
        lines.append(f"- note: {message}")
    lines.append("- Duration: 0s")
    lines.append("")

    header = "# localai update log\n\nNewest first.\n\n"
    existing = path.read_text(encoding="utf-8") if path.exists() else header
    marker = "Newest first.\n\n"
    if marker in existing:
        prefix, rest = existing.split(marker, 1)
        content = prefix + marker + "\n".join(lines) + "\n" + rest
    else:
        content = existing + "\n".join(lines) + "\n"
    path.write_text(content, encoding="utf-8")
