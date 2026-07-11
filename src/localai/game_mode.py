"""Game Mode cleanup ported from Stop-AI-For-Gaming.ps1."""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from importlib import import_module
from pathlib import Path
from typing import Any, cast
from urllib.error import URLError
from urllib.request import urlopen

from localai.ops import run_command
from localai.paths import REPO_ROOT, repo_path


@dataclass(frozen=True)
class ProcessInfo:
    pid: int
    name: str
    command_line: str


def collect_game_mode_report(
    *,
    keep_docker: bool = False,
    keep_wsl: bool = False,
    disable_warm_task: bool = False,
    dry_run: bool = False,
    ollama_timeout_sec: int = 20,
) -> tuple[int, list[str]]:
    """Run or preview the same cleanup steps as Stop-AI-For-Gaming.ps1."""
    lines = ["==== AI game mode cleanup ===="]
    if dry_run:
        lines.append(
            "[dry-run] No models, containers, tasks, or WSL processes will be stopped."
        )

    ollama = ollama_path()
    compose = repo_path("docker-compose.yml")
    docker = docker_path()

    if disable_warm_task:
        lines.append("[0/4] Disabling AI-Warm logon preload...")
        if dry_run:
            lines.append("  would disable scheduled task AI-Warm")
        else:
            result = run_command(
                ["schtasks", "/Change", "/TN", "AI-Warm", "/Disable"],
                cwd=REPO_ROOT,
                timeout_sec=30,
            )
            if result.code == 0:
                lines.append("  AI-Warm disabled")
            else:
                lines.append(f"  could not disable AI-Warm: {result.text.strip()}")

    if ollama.exists():
        lines.append("[1/4] Unloading Ollama models...")
        models, messages = get_loaded_ollama_models(ollama, ollama_timeout_sec)
        lines.extend(messages)
        if not models:
            lines.append("  no loaded models")
        else:
            for model in models:
                if dry_run:
                    lines.append(f"  would ollama stop {model}")
                else:
                    lines.append(f"  ollama stop {model}")
                    result = run_command(
                        [str(ollama), "stop", model],
                        cwd=REPO_ROOT,
                        timeout_sec=ollama_timeout_sec,
                    )
                    if result.code != 0:
                        lines.append(f"    failed or timed out: {result.text.strip()}")
    else:
        lines.append("[1/4] Ollama not found; skipping.")

    lines.append("[2/4] Stopping ComfyUI/Image Studio if running...")
    comfy_processes, process_messages = get_comfyui_processes()
    lines.extend(process_messages)
    if not comfy_processes:
        lines.append("  no ComfyUI process found")
    for process in comfy_processes:
        if dry_run:
            lines.append(f"  would stop PID {process.pid} {process.name}")
        else:
            lines.append(f"  stopping PID {process.pid} {process.name}")
            run_command(["taskkill", "/PID", str(process.pid), "/F"], cwd=REPO_ROOT)

    if not keep_docker and compose.exists():
        lines.append("[3/4] Stopping localai Docker containers...")
        if dry_run:
            lines.append(f"  would run: docker compose -f {compose} down")
        else:
            result = run_command(
                [str(docker), "compose", "-f", str(compose), "down"],
                cwd=REPO_ROOT,
                timeout_sec=90,
            )
            text = result.text.strip()
            if result.code == 0:
                lines.append(text if text else "  containers stopped")
            else:
                lines.append(f"  docker compose down failed or timed out: {text}")
    else:
        lines.append("[3/4] Docker cleanup skipped.")

    if not keep_wsl:
        lines.append("[4/4] Releasing WSL/Docker memory...")
        if dry_run:
            lines.append("  would run: wsl --shutdown")
        else:
            result = run_command(
                ["wsl.exe", "--shutdown"],
                cwd=REPO_ROOT,
                timeout_sec=45,
            )
            if result.code == 0:
                lines.append("  WSL shutdown requested")
            else:
                lines.append(
                    f"  wsl --shutdown failed or timed out: {result.text.strip()}"
                )
    else:
        lines.append("[4/4] WSL shutdown skipped.")

    lines.append("")
    lines.append("Post-check loaded Ollama models:")
    if ollama.exists():
        post_models, post_messages = get_loaded_ollama_models(
            ollama,
            ollama_timeout_sec,
        )
        lines.extend(post_messages)
        if post_models:
            lines.append("  " + ", ".join(post_models))
        else:
            lines.append("  no loaded models")
    else:
        lines.append("  Ollama not found.")

    lines.append("")
    lines.append(
        "Game mode cleanup complete. Run 'localai start' when you want Open "
        "WebUI back."
    )
    return 0, lines


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


def get_loaded_ollama_models(
    ollama: Path,
    timeout_sec: int,
) -> tuple[list[str], list[str]]:
    try:
        with urlopen("http://localhost:11434/api/ps", timeout=5) as response:
            payload = json.loads(response.read().decode("utf-8"))
        models = []
        for row in payload.get("models", []):
            name = row.get("name") or row.get("model")
            if name:
                models.append(str(name))
        return models, []
    except (OSError, TimeoutError, URLError, json.JSONDecodeError):
        result = run_command(
            [str(ollama), "ps"],
            cwd=REPO_ROOT,
            timeout_sec=timeout_sec,
        )
        text = result.text.strip()
        if result.code != 0 or not text:
            message = "  ollama ps failed or timed out."
            if text:
                message = f"{message} {text}"
            return [], [message]
        return parse_ollama_ps(text), []


def parse_ollama_ps(text: str) -> list[str]:
    models = []
    for line in text.splitlines()[1:]:
        parts = line.split()
        if parts:
            models.append(parts[0].strip())
    return [model for model in models if model]


def get_comfyui_processes() -> tuple[list[ProcessInfo], list[str]]:
    processes, messages = query_windows_processes()
    if messages:
        return [], messages
    return [process for process in processes if is_comfyui_process(process)], []


def query_windows_processes() -> tuple[list[ProcessInfo], list[str]]:
    try:
        win32com_client = cast(Any, import_module("win32com.client"))
    except ModuleNotFoundError:
        return [], [
            "  could not inspect ComfyUI process command lines: pywin32 is not "
            "installed"
        ]

    try:
        service = win32com_client.GetObject("winmgmts:root\\cimv2")
        rows = service.ExecQuery(
            "SELECT ProcessId,Name,CommandLine FROM Win32_Process"
        )
    except Exception as exc:
        return [], [
            "  could not inspect ComfyUI process command lines: "
            f"{format_wmi_error(exc)}"
        ]

    processes = []
    for row in rows:
        process = process_from_wmi_row(row)
        if process is not None:
            processes.append(process)
    return processes, []


def process_from_wmi_row(row: Any) -> ProcessInfo | None:
    try:
        pid = int(row.ProcessId)
    except (AttributeError, TypeError, ValueError):
        return None
    name = str(getattr(row, "Name", "") or "").strip()
    command_line = str(getattr(row, "CommandLine", "") or "").strip()
    return ProcessInfo(pid=pid, name=name, command_line=command_line)


def format_wmi_error(exc: BaseException) -> str:
    text = str(exc).strip()
    if "Access denied" in text:
        return "Access to a CIM resource was not available to the client."
    return text if text else exc.__class__.__name__


def is_comfyui_process(process: ProcessInfo) -> bool:
    if not process.command_line:
        return False
    return (
        re.search(
            r"ComfyUI\\main\.py|ComfyUI_windows_portable",
            process.command_line,
        )
        is not None
    )
