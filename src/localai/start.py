"""Start plan and live launcher for the localai stack, ported from Start-LocalAI.bat."""

from __future__ import annotations

import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
import webbrowser
from collections.abc import Callable
from pathlib import Path

from localai.anywhere import collect_anywhere_report
from localai.compose import docker_env
from localai.health import collect_health_report
from localai.model_aliases import collect_model_aliases_report
from localai.ops import run_command
from localai.paths import REPO_ROOT
from localai.warm import collect_warm_report, read_warm_model_override

OLLAMA_TAGS_URL = "http://localhost:11434/api/tags"
OPEN_WEBUI_URL = "http://localhost:3000"


def collect_start_report(
    *,
    dry_run: bool = False,
    no_open: bool = False,
) -> tuple[int, list[str]]:
    """Start the localai stack, or preview the sequence with ``dry_run``.

    The live path mirrors Start-LocalAI.bat: bring up Ollama and Docker, run
    ``docker compose up -d``, then delegate model aliases, warm-up, Tailscale
    Serve, and the health check to the already-ported Python collectors. The
    .bat fatal/non-fatal map is preserved: the Ollama/Docker waits, ``compose
    up``, model aliases, and the health check are fatal; warm-up and Tailscale
    Serve only warn.
    """
    if dry_run:
        return _dry_run_report(no_open=no_open)
    return _live_start(no_open=no_open)


def _live_start(*, no_open: bool) -> tuple[int, list[str]]:
    lines: list[str] = ["Starting your local AI..."]

    lines.append("[1/9] Ollama app")
    if _ollama_api_ready():
        lines.append("  Ollama already reachable.")
    elif _launch_detached(ollama_app_path()):
        lines.append(f"  Launched {ollama_app_path()}.")
    else:
        lines.append(f"  WARN: could not launch Ollama app at {ollama_app_path()}.")

    lines.append("[2/9] Ollama API")
    if not _wait_until(_ollama_api_ready, attempts=30, interval_sec=2):
        lines.append(f"  ERROR: Ollama did not become reachable at {OLLAMA_TAGS_URL}.")
        lines.append("  Start Ollama manually, then run start again.")
        return 1, lines
    lines.append("  Ollama API reachable.")

    lines.append("[3/9] Docker Desktop")
    if _docker_ready():
        lines.append("  Docker engine already running.")
    elif _launch_detached(docker_desktop_path()):
        lines.append(f"  Launched {docker_desktop_path()}.")
    else:
        lines.append(
            f"  WARN: could not launch Docker Desktop at {docker_desktop_path()}."
        )

    lines.append("[4/9] Docker engine")
    if not _wait_until(_docker_ready, attempts=36, interval_sec=5):
        lines.append("  ERROR: Docker engine did not become reachable after 3 minutes.")
        lines.append("  Start Docker Desktop manually, then run start again.")
        return 1, lines
    lines.append("  Docker engine reachable.")

    lines.append("[5/9] Open WebUI + SearXNG + Kokoro")
    up = run_command(
        ["docker", "compose", "up", "-d"],
        cwd=REPO_ROOT,
        env=docker_env(),
        timeout_sec=300,
    )
    if up.code != 0:
        lines.append("  ERROR: docker compose up -d failed.")
        lines.extend(_indent_text(up.text))
        return 1, lines
    lines.append("  Compose stack is up.")

    lines.append("[6/9] Purpose-based model names")
    # lenient: missing sources (a clean / tier-B box lacks this box's full zoo)
    # are skipped, not fatal; a real `ollama cp` failure still fails start
    # (audit finding 2 / ref-box #2).
    alias_code, alias_lines = collect_model_aliases_report(lenient=True)
    lines.extend(_indent(alias_lines))
    if alias_code != 0:
        lines.append("  ERROR: model alias refresh failed.")
        return 1, lines

    warm_model = read_warm_model_override()
    lines.append(
        f"[7/9] Warm model ({warm_model})" if warm_model else "[7/9] Warm default model"
    )
    _, warm_lines = collect_warm_report(
        model=warm_model,
        prefer_target=warm_model is not None,
        unload_others=True,
        skip_if_any_loaded=True,
    )
    lines.extend(_indent(warm_lines))

    lines.append("[8/9] Tailscale Serve")
    aw_code, aw_lines = collect_anywhere_report(apply=True)
    lines.extend(_indent(aw_lines))
    if aw_code != 0:
        lines.append(
            "  WARN: Tailscale Serve reported a problem; local chat still works."
        )

    lines.append("[9/9] Health check and final warm")
    health_code, health_lines = collect_health_report()
    lines.extend(_indent(health_lines))
    if health_code != 0:
        lines.append("  ERROR: health check failed.")
        return 1, lines
    _, warm2_lines = collect_warm_report(
        model=warm_model,
        prefer_target=warm_model is not None,
        unload_others=True,
        skip_if_any_loaded=True,
    )
    lines.extend(_indent(warm2_lines))

    if no_open:
        lines.append("  Browser launch skipped (--no-open).")
    elif _open_browser(OPEN_WEBUI_URL):
        lines.append(f"  Opened {OPEN_WEBUI_URL}.")
    else:
        lines.append(f"  WARN: could not open a browser; visit {OPEN_WEBUI_URL}.")

    lines.append("")
    lines.append("Local AI is UP: this PC -> http://localhost:3000")
    return 0, lines


def _dry_run_report(*, no_open: bool) -> tuple[int, list[str]]:
    lines = [
        "==== localai start dry-run ====",
        "[dry-run] No processes, containers, Tailscale routes, models, or browser "
        "windows will be started.",
        "Starting your local AI...",
        "[1/9] Ollama app",
        f"  would start {ollama_app_path()} if its API is not reachable",
        "[2/9] Ollama API",
        "  would wait up to 60s for http://localhost:11434/api/tags",
        "[3/9] Docker Desktop",
        f"  would start {docker_desktop_path()} if the engine is not reachable",
        "[4/9] Docker engine",
        "  would wait up to 3 minutes for docker info",
        "[5/9] Open WebUI + SearXNG + Kokoro",
        "  would run: docker compose up -d",
        "[6/9] Purpose-based model names",
        "  would run: localai model-aliases",
        "[7/9] Warm default model",
        "  would run: localai warm --unload-others --skip-if-any-loaded",
        "[8/9] Tailscale Serve",
        "  would run: localai anywhere --apply",
        "[9/9] Health check and final warm",
        "  would run: localai health",
        "  would run: localai warm --unload-others --skip-if-any-loaded",
    ]
    if no_open:
        lines.append("  Browser launch skipped because --no-open was passed.")
    else:
        lines.append("  would open: http://localhost:3000")
    lines.extend(["", "Local AI start dry-run complete."])
    return 0, lines


def _ollama_api_ready(timeout_sec: float = 2.0) -> bool:
    try:
        with urllib.request.urlopen(OLLAMA_TAGS_URL, timeout=timeout_sec) as response:
            response.read(1)
        return True
    except (OSError, urllib.error.URLError):
        return False


def _docker_ready(timeout_sec: int = 20) -> bool:
    result = run_command(
        ["docker", "info"],
        cwd=REPO_ROOT,
        env=docker_env(),
        timeout_sec=timeout_sec,
    )
    return result.code == 0


def _wait_until(
    predicate: Callable[[], bool],
    *,
    attempts: int,
    interval_sec: float,
) -> bool:
    for index in range(attempts):
        if predicate():
            return True
        if index < attempts - 1:
            time.sleep(interval_sec)
    return False


def _launch_detached(path: Path) -> bool:
    if not path.exists():
        return False
    flags = 0
    if sys.platform == "win32":
        flags = getattr(subprocess, "DETACHED_PROCESS", 0) | getattr(
            subprocess, "CREATE_NEW_PROCESS_GROUP", 0
        )
    try:
        subprocess.Popen([str(path)], creationflags=flags, close_fds=True)
    except OSError:
        return False
    return True


def _open_browser(url: str) -> bool:
    try:
        return webbrowser.open(url)
    except OSError:
        return False


def _indent(sub_lines: list[str]) -> list[str]:
    return [f"  {line}" for line in sub_lines]


def _indent_text(text: str) -> list[str]:
    return [f"  {line}" for line in text.splitlines() if line.strip()]


def ollama_app_path() -> Path:
    return (
        Path(os.environ.get("LOCALAPPDATA", ""))
        / "Programs"
        / "Ollama"
        / "ollama app.exe"
    )


def docker_desktop_path() -> Path:
    return (
        Path(os.environ.get("PROGRAMFILES", ""))
        / "Docker"
        / "Docker"
        / "Docker Desktop.exe"
    )
