"""Purpose-based Ollama aliases ported from ai-model-aliases.ps1."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from time import sleep
from urllib.error import URLError
from urllib.request import urlopen

from localai.health import ALIAS_SOURCES
from localai.ops import run_command
from localai.paths import REPO_ROOT


@dataclass(frozen=True)
class ModelAlias:
    alias: str
    source: str
    use: str


ALIASES: tuple[ModelAlias, ...] = (
    ModelAlias(
        "deep-thinking-qwen3.6",
        "qwen3.6-thinklight-grounded",
        "Think-light Qwen3.6; avoids long hidden loops",
    ),
    ModelAlias(
        "full-thinking-qwen3.6",
        "qwen3.6-35b-a3b-grounded",
        "Full Qwen3.6 thinking; slow and only for hard problems",
    ),
    ModelAlias(
        "voice-qwen3-grounded",
        "qwen3-grounded",
        "Voice default; strong and responsive",
    ),
    ModelAlias(
        "fast-voice-qwen2.5-14b",
        "qwen2.5:14b",
        "Fastest voice / quick replies",
    ),
    ModelAlias(
        "image-prompt-qwen3-grounded",
        "qwen3-grounded",
        "Image prompt help after unloading big chat model",
    ),
    ModelAlias(
        "image-fast-prompt-qwen2.5-14b",
        "qwen2.5:14b",
        "Fast image prompt help",
    ),
    ModelAlias(
        "web-search-qwen3-grounded",
        "qwen3-grounded",
        "Web search default; faster synthesis",
    ),
    ModelAlias(
        "web-search-deep-qwen3.6",
        "qwen3.6-thinklight-grounded",
        "Web search with Qwen3.6 quality, capped thinking",
    ),
    ModelAlias(
        "terminal-code-qwen2.5-coder-14b",
        "qwen2.5-coder:14b",
        "Smooth local terminal coding agent",
    ),
    ModelAlias(
        "terminal-agent-qwen3-coder-30b",
        "qwen3-coder:30b",
        "Deep local terminal coding agent; heavier",
    ),
    ModelAlias("vision-qwen2.5vl-7b", "qwen2.5vl:7b", "Local image understanding"),
)


def collect_model_aliases_report(
    *,
    dry_run: bool = False,
    wait_attempts: int = 30,
    wait_interval_sec: float = 2,
    lenient: bool = False,
) -> tuple[int, list[str]]:
    """Create or preview the purpose-based Ollama aliases.

    A **missing source model** and a **failed ``ollama cp``** are different
    problems: the first is expected on any box that lacks this machine's full
    model zoo (a clean or tier-B install), the second is a real error. By default
    both are fatal (legacy contract). With ``lenient=True`` only real copy
    failures are fatal -- missing sources are skipped -- so ``localai start`` on a
    clean box does not die at the aliases step (audit finding 2 / ref-box #2).
    """
    ollama = ollama_path()
    if not ollama.exists():
        return 1, [f"Ollama not found at {ollama}"]

    if not wait_for_ollama_api(wait_attempts, wait_interval_sec):
        return 1, ["Ollama server is not reachable."]

    existing = get_model_name_set(ollama)
    lines: list[str] = []
    missing = 0
    errors = 0
    for row in ALIASES:
        if row.source not in existing:
            lines.append(
                f"WARNING: Skipping {row.alias}: source model "
                f"'{row.source}' is missing."
            )
            missing += 1
            continue

        if dry_run:
            lines.append(format_alias_line(row, prefix="[dry-run] would alias"))
            continue

        result = run_command(
            [str(ollama), "cp", row.source, row.alias],
            cwd=REPO_ROOT,
            timeout_sec=120,
        )
        if result.code == 0:
            lines.append(format_alias_line(row))
        else:
            lines.append(
                f"WARNING: Failed to create {row.alias}: {result.text.strip()}"
            )
            errors += 1

    if missing and lenient:
        lines.append(
            f"NOTE: {missing} alias source(s) absent on this machine; "
            "skipped (non-fatal)."
        )
    fatal = errors + (0 if lenient else missing)
    return (1 if fatal else 0), lines


def ollama_path() -> Path:
    return (
        Path(os.environ.get("LOCALAPPDATA", ""))
        / "Programs"
        / "Ollama"
        / "ollama.exe"
    )


def wait_for_ollama_api(attempts: int, interval_sec: float) -> bool:
    for _ in range(attempts):
        try:
            with urlopen("http://localhost:11434/api/tags", timeout=3) as response:
                response.read(1)
            return True
        except (OSError, TimeoutError, URLError):
            if interval_sec > 0:
                sleep(interval_sec)
    return False


def get_model_name_set(ollama: Path) -> set[str]:
    result = run_command([str(ollama), "list"], cwd=REPO_ROOT, timeout_sec=30)
    if result.code != 0:
        return set()
    return parse_ollama_list_names(result.text)


def parse_ollama_list_names(text: str) -> set[str]:
    names: set[str] = set()
    for line in text.splitlines()[1:]:
        parts = line.split()
        if not parts:
            continue
        name = parts[0].strip()
        if not name:
            continue
        names.add(name)
        if name.endswith(":latest"):
            names.add(name.removesuffix(":latest"))
    return names


def format_alias_line(row: ModelAlias, *, prefix: str = "[alias]") -> str:
    return f"{prefix} {row.alias:<34} -> {row.source:<30} {row.use}"


def alias_source_map_matches_health_contract() -> bool:
    return {row.alias: row.source for row in ALIASES} == ALIAS_SOURCES
