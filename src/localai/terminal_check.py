"""Terminal AI readiness check ported from ai-terminal-check.ps1."""

from __future__ import annotations

import json
import os
import shutil
import socket
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from urllib.error import URLError
from urllib.request import urlopen

from localai.ops import run_command
from localai.paths import REPO_ROOT, repo_path

AddLine = Callable[[str, str, str], None]


TERMINAL_COMMANDS = (
    "ai-chat",
    "ai-deepchat",
    "ai-code",
    "ai-deepcode",
    "ai-web",
    "ai-vision",
    "ai-image",
    "ai-models",
    "ai-doctor",
    "ai-start",
    "ai-game-mode",
    "ai-agent",
)

NEEDED_MODELS = (
    "qwen2.5-grounded",
    "deep-thinking-qwen3.6",
    "terminal-code-qwen2.5-coder-14b",
    "terminal-agent-qwen3-coder-30b",
    "vision-qwen2.5vl-7b",
    "web-search-qwen3-grounded",
)


@dataclass
class Counters:
    ok: int = 0
    warn: int = 0
    fail: int = 0

    def add(self, status: str) -> None:
        if status == "OK":
            self.ok += 1
        elif status == "WARN":
            self.warn += 1
        elif status == "FAIL":
            self.fail += 1


def collect_terminal_check_report(
    *,
    strict: bool = False,
    now: datetime | None = None,
) -> tuple[int, list[str]]:
    """Collect the same read-only checks as ai-terminal-check.ps1."""
    counters = Counters()
    stamp = (now or datetime.now()).strftime("%Y-%m-%d %H:%M:%S")
    lines = [f"==== localai terminal readiness ====  {stamp}"]

    def add_line(status: str, name: str, detail: str) -> None:
        counters.add(status)
        lines.append(format_status_line(status, name, detail))

    check_start_terminal_ai(add_line)
    bin_dir = Path.home() / ".local" / "bin"
    check_terminal_path(add_line, bin_dir)
    check_terminal_commands(add_line, bin_dir)
    check_pwsh(add_line)
    check_ollama_binary(add_line)
    check_ollama_models(add_line)
    check_aider(add_line)
    check_image_generator(add_line)
    check_searx(add_line)

    lines.append("")
    lines.append(
        f"Summary: {counters.ok} OK, {counters.warn} WARN, {counters.fail} FAIL"
    )
    if counters.fail > 0:
        return 1, lines
    if strict and counters.warn > 0:
        return 1, lines
    return 0, lines


def format_status_line(status: str, name: str, detail: str) -> str:
    return f"[{status}] {name:<24} {detail}"


def check_start_terminal_ai(add_line: AddLine) -> None:
    launcher = repo_path("Start-TerminalAI.ps1")
    if not launcher.exists():
        add_line("FAIL", "Start-TerminalAI", f"missing: {launcher}")
        return

    pwsh = resolve_command_source("pwsh.exe") or resolve_command_source("pwsh")
    if pwsh is None:
        add_line("FAIL", "Start-TerminalAI", "pwsh.exe not found")
        return

    command = (
        "$null = [scriptblock]::Create("
        f"(Get-Content -LiteralPath '{escape_single_quotes(str(launcher))}' -Raw))"
    )
    result = run_command(
        [pwsh, "-NoProfile", "-Command", command],
        cwd=REPO_ROOT,
        timeout_sec=10,
    )
    if result.code == 0:
        add_line("OK", "Start-TerminalAI", "syntax OK")
    else:
        add_line("FAIL", "Start-TerminalAI", result.text.strip() or "syntax failed")


def check_terminal_path(add_line: AddLine, bin_dir: Path) -> None:
    if bin_dir.is_dir():
        if path_list_contains(bin_dir):
            add_line("OK", "terminal PATH", f"{bin_dir} is on PATH")
        else:
            add_line(
                "WARN",
                "terminal PATH",
                f"{bin_dir} exists but is not on PATH for this shell",
            )
    else:
        add_line("FAIL", "terminal PATH", f"{bin_dir} is missing")


def check_terminal_commands(add_line: AddLine, bin_dir: Path) -> None:
    for name in TERMINAL_COMMANDS:
        source = resolve_terminal_wrapper(name, bin_dir)
        if source:
            add_line("OK", name, source)
            continue
        cmd_file = bin_dir / f"{name}.cmd"
        if cmd_file.exists():
            add_line(
                "WARN",
                name,
                f"wrapper exists but command did not resolve: {cmd_file}",
            )
        else:
            add_line("FAIL", name, "missing")


def check_pwsh(add_line: AddLine) -> None:
    pwsh = resolve_command_source("pwsh.exe") or resolve_command_source("pwsh")
    if pwsh:
        add_line("OK", "PowerShell 7", pwsh)
    else:
        add_line("FAIL", "PowerShell 7", "pwsh.exe not found")


def check_ollama_binary(add_line: AddLine) -> None:
    local_app_data = os.environ.get("LOCALAPPDATA", "")
    ollama = Path(local_app_data) / "Programs" / "Ollama" / "ollama.exe"
    if ollama.exists():
        add_line("OK", "Ollama binary", str(ollama))
    else:
        add_line("FAIL", "Ollama binary", f"missing: {ollama}")


def check_ollama_models(add_line: AddLine) -> None:
    model_names = get_ollama_model_names()
    if model_names is None:
        add_line("WARN", "Ollama API", "not reachable; model alias checks skipped")
        return

    add_line("OK", "Ollama API", f"{len(model_names)} model(s) visible")
    for model in NEEDED_MODELS:
        if model_known(model_names, model):
            add_line("OK", model, "available")
        else:
            add_line(
                "WARN",
                model,
                "missing; run ai-model-aliases.ps1 or ai-update.ps1",
            )


def check_aider(add_line: AddLine) -> None:
    aider = resolve_command_source("aider")
    if not aider:
        add_line("WARN", "Aider", "not found; ai-code falls back to Ollama advice only")
        return

    result = run_command(["aider", "--version"], cwd=REPO_ROOT, timeout_sec=15)
    detail = normalize_aider_version(result.text) if result.text else aider
    if result.code == 0:
        add_line("OK", "Aider", detail)
    else:
        add_line("WARN", "Aider", detail)


def check_image_generator(add_line: AddLine) -> None:
    image_generator = Path.home() / "imageai" / "generate.ps1"
    if image_generator.exists():
        add_line("OK", "Image generator", str(image_generator))
    else:
        add_line("WARN", "Image generator", f"missing: {image_generator}")


def check_searx(add_line: AddLine) -> None:
    if tcp_port_ready("127.0.0.1", 8080, timeout_sec=0.75):
        add_line("OK", "ai-web dependency", "SearXNG port 8080 is reachable")
    else:
        add_line(
            "WARN",
            "ai-web dependency",
            "SearXNG is not reachable; Start Local AI before ai-web",
        )


def resolve_command_source(name: str) -> str | None:
    if name.lower() in {"pwsh.exe", "pwsh"}:
        where = run_command(["where.exe", name], cwd=REPO_ROOT, timeout_sec=5)
        for line in where.stdout.splitlines():
            if line.strip():
                return line.strip()

    path = shutil.which(name)
    if path:
        return path
    return None


def resolve_terminal_wrapper(name: str, bin_dir: Path) -> str | None:
    cmd_file = bin_dir / f"{name}.cmd"
    if cmd_file.exists():
        return str(cmd_file)
    return resolve_command_source(name)


def path_list_contains(directory: Path, path_value: str | None = None) -> bool:
    target = normalize_path_for_compare(directory)
    source = path_value if path_value is not None else os.environ.get("PATH", "")
    entries = source.split(os.pathsep)
    return any(
        normalize_path_for_compare(Path(entry)) == target for entry in entries if entry
    )


def normalize_path_for_compare(path: Path) -> str:
    return os.path.normcase(os.path.abspath(path)).rstrip("\\/")


def get_ollama_model_names() -> list[str] | None:
    try:
        with urlopen("http://localhost:11434/api/tags", timeout=5) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except (OSError, TimeoutError, URLError, json.JSONDecodeError):
        return None

    names: list[str] = []
    for row in payload.get("models", []):
        if not isinstance(row, dict):
            continue
        name = row.get("name") or row.get("model")
        if name:
            names.append(str(name))
    return names


def model_known(names: list[str], model: str) -> bool:
    return any(name == model or name.startswith(f"{model}:") for name in names)


def tcp_port_ready(host: str, port: int, *, timeout_sec: float) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout_sec):
            return True
    except OSError:
        return False


def collapse_whitespace(text: str) -> str:
    return " ".join(text.split())


def normalize_aider_version(text: str) -> str:
    detail = collapse_whitespace(text)
    if detail.lower().startswith("aider.exe "):
        return "aider " + detail.split(" ", 1)[1]
    return detail


def escape_single_quotes(text: str) -> str:
    return text.replace("'", "''")
