"""Stop the local AI stack, ported from Stop-LocalAI.ps1."""

from __future__ import annotations

import json
import os
from pathlib import Path
from urllib.error import URLError
from urllib.request import urlopen

from localai.ops import run_command
from localai.paths import REPO_ROOT, repo_path


def collect_stop_report(
    *,
    keep_containers: bool = False,
    keep_models: bool = False,
    keep_apps: bool = False,
    timeout_sec: int = 90,
) -> tuple[int, list[str]]:
    """Stop the stack: unload models, stop containers, and quit Docker + Ollama.

    ``keep_apps`` leaves Docker Desktop and the Ollama tray app running (the old
    behaviour); by default Stop now fully closes both so the machine is idle.
    """
    lines = ["==== Stop Local AI ===="]
    ollama = ollama_path()
    compose = repo_path("docker-compose.yml")
    docker = docker_path()

    if keep_models:
        lines.append("[1/3] Model unload skipped.")
    elif ollama.exists():
        lines.append("[1/3] Unloading Ollama models...")
        try:
            models = get_loaded_ollama_models()
            if not models:
                lines.append("  no loaded models")
            for model in models:
                lines.append(f"  ollama stop {model}")
                result = invoke_native_bounded(
                    f"ollama stop {model}",
                    [str(ollama), "stop", model],
                    timeout_sec,
                )
                if result is not None:
                    lines.append(f"WARNING: {result}")
        except (OSError, TimeoutError, URLError, json.JSONDecodeError) as exc:
            lines.append(
                "WARNING: Could not query loaded Ollama models: "
                f"{exception_message(exc)}"
            )
    else:
        lines.append("[1/3] Ollama not found; skipping model unload.")

    if keep_containers or not compose.exists():
        lines.append("[2/3] Container stop skipped.")
    else:
        lines.append("[2/3] Stopping localai Docker containers...")
        result = invoke_native_bounded(
            "docker compose down",
            [str(docker), "compose", "-f", str(compose), "down"],
            timeout_sec,
        )
        if result is not None:
            lines.append(f"WARNING: {result}")

    if keep_apps:
        lines.append("[3/3] Leaving Docker Desktop and Ollama running (--keep-apps).")
        lines.append("")
        lines.append("Post-check loaded Ollama models:")
        if ollama.exists():
            result = invoke_native_bounded(
                "ollama ps",
                [str(ollama), "ps"],
                timeout_sec,
                return_success_text=True,
            )
            if result is None:
                lines.append("  no loaded models")
            elif result.startswith("SUCCESS:"):
                text = result.removeprefix("SUCCESS:").strip()
                lines.append(text if text else "  no loaded models")
            else:
                lines.append(f"WARNING: {result}")
        else:
            lines.append("  Ollama not found.")
    else:
        lines.append("[3/3] Closing Docker Desktop and Ollama...")
        lines.extend(close_desktop_apps(timeout_sec))

    lines.append("")
    lines.append("Local AI stop complete.")
    return 0, lines


# Image names taskkill matches, newest-first so children die before parents.
_OLLAMA_IMAGES = ("ollama app.exe", "ollama.exe")
_DOCKER_IMAGES = (
    "Docker Desktop.exe",
    "com.docker.backend.exe",
    "com.docker.build.exe",
)


def close_desktop_apps(timeout_sec: int) -> list[str]:
    """Force-close the Ollama tray app and Docker Desktop by image name.

    taskkill exits 128 when nothing matches - that means 'already closed', so it
    is reported as info, not a warning.
    """
    lines: list[str] = []
    targets = (("Ollama", _OLLAMA_IMAGES), ("Docker Desktop", _DOCKER_IMAGES))
    for label, images in targets:
        closed_any = False
        for image in images:
            result = run_command(
                ["taskkill", "/IM", image, "/F", "/T"],
                cwd=REPO_ROOT,
                timeout_sec=timeout_sec,
            )
            if result.code == 0:
                closed_any = True
            elif result.code == 124:
                lines.append(f"  WARNING: taskkill {image} timed out")
        lines.append(f"  {label} closed." if closed_any else f"  {label} not running.")
    return lines


def ollama_path() -> Path:
    local_app_data = os.environ.get("LOCALAPPDATA", "")
    return Path(local_app_data) / "Programs" / "Ollama" / "ollama.exe"


def docker_path() -> Path | str:
    program_files = os.environ.get("PROGRAMFILES", "")
    docker = (
        Path(program_files)
        / "Docker"
        / "Docker"
        / "resources"
        / "bin"
        / "docker.exe"
    )
    return docker if docker.exists() else "docker"


def get_loaded_ollama_models() -> list[str]:
    with urlopen("http://localhost:11434/api/ps", timeout=3) as response:
        payload = json.loads(response.read().decode("utf-8"))
    models = payload.get("models", []) if isinstance(payload, dict) else []
    names = []
    for row in models:
        if isinstance(row, dict) and row.get("name"):
            names.append(str(row["name"]))
    return names


def invoke_native_bounded(
    label: str,
    args: list[str],
    timeout_sec: int,
    *,
    return_success_text: bool = False,
) -> str | None:
    result = run_command(args, cwd=REPO_ROOT, timeout_sec=timeout_sec)
    if result.code == 124:
        return f"{label} timed out after {timeout_sec}s"
    text = result.text.strip()
    if result.code != 0:
        return f"{label} failed with exit {result.code}. {text}"
    if return_success_text:
        return f"SUCCESS:{text}"
    return None


def exception_message(exc: BaseException) -> str:
    return str(exc)
