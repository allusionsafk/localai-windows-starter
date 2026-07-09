from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest

from localai import stop
from localai.ops import CommandResult
from localai.paths import REPO_ROOT


def test_stop_keep_flags_still_run_post_check(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    ollama = Path("C:/fake/Ollama/ollama.exe")
    original_exists = Path.exists

    def fake_exists(path: Path) -> bool:
        if path == ollama:
            return True
        return original_exists(path)

    def fake_run_command(
        args: list[str],
        *,
        cwd: Path,
        timeout_sec: int,
    ) -> CommandResult:
        assert args == [str(ollama), "ps"]
        assert cwd == REPO_ROOT
        assert timeout_sec == 90
        return CommandResult(tuple(args), 0, "", "")

    monkeypatch.setattr(stop, "ollama_path", lambda: ollama)
    monkeypatch.setattr(Path, "exists", fake_exists)
    monkeypatch.setattr(stop, "run_command", fake_run_command)

    code, lines = stop.collect_stop_report(
        keep_models=True,
        keep_containers=True,
        keep_apps=True,
    )

    assert code == 0
    assert lines == [
        "==== Stop Local AI ====",
        "[1/3] Model unload skipped.",
        "[2/3] Container stop skipped.",
        "[3/3] Leaving Docker Desktop and Ollama running (--keep-apps).",
        "",
        "Post-check loaded Ollama models:",
        "  no loaded models",
        "",
        "Local AI stop complete.",
    ]


def test_stop_unloads_models_and_warns_without_failing(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    ollama = Path("C:/fake/Ollama/ollama.exe")
    original_exists = Path.exists
    commands: list[tuple[str, ...]] = []

    def fake_exists(path: Path) -> bool:
        if path == ollama:
            return True
        return original_exists(path)

    def fake_get_loaded_ollama_models() -> list[str]:
        return ["qwen:latest"]

    def fake_run_command(
        args: list[str],
        *,
        cwd: Path,
        timeout_sec: int,
    ) -> CommandResult:
        assert cwd == REPO_ROOT
        assert timeout_sec == 12
        commands.append(tuple(args))
        if args == [str(ollama), "stop", "qwen:latest"]:
            return CommandResult(tuple(args), 1, "", "already stopped\n")
        if args == [str(ollama), "ps"]:
            return CommandResult(tuple(args), 0, "NAME ID SIZE PROCESSOR UNTIL\n", "")
        msg = f"unexpected command {args}"
        raise AssertionError(msg)

    monkeypatch.setattr(stop, "ollama_path", lambda: ollama)
    monkeypatch.setattr(Path, "exists", fake_exists)
    monkeypatch.setattr(stop, "get_loaded_ollama_models", fake_get_loaded_ollama_models)
    monkeypatch.setattr(stop, "run_command", fake_run_command)

    code, lines = stop.collect_stop_report(
        keep_containers=True,
        keep_apps=True,
        timeout_sec=12,
    )

    assert code == 0
    assert commands == [
        (str(ollama), "stop", "qwen:latest"),
        (str(ollama), "ps"),
    ]
    assert lines == [
        "==== Stop Local AI ====",
        "[1/3] Unloading Ollama models...",
        "  ollama stop qwen:latest",
        "WARNING: ollama stop qwen:latest failed with exit 1. already stopped",
        "[2/3] Container stop skipped.",
        "[3/3] Leaving Docker Desktop and Ollama running (--keep-apps).",
        "",
        "Post-check loaded Ollama models:",
        "NAME ID SIZE PROCESSOR UNTIL",
        "",
        "Local AI stop complete.",
    ]


def test_stop_container_failure_is_warning_only(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    ollama = Path("C:/missing/Ollama/ollama.exe")

    def fake_run_command(
        args: list[str],
        *,
        cwd: Path,
        timeout_sec: int,
    ) -> CommandResult:
        assert args[1:] == [
            "compose",
            "-f",
            str(REPO_ROOT / "docker-compose.yml"),
            "down",
        ]
        assert cwd == REPO_ROOT
        assert timeout_sec == 9
        return CommandResult(tuple(args), 124, "", "timeout text\n")

    monkeypatch.setattr(stop, "ollama_path", lambda: ollama)
    monkeypatch.setattr(stop, "docker_path", lambda: "docker")
    monkeypatch.setattr(stop, "run_command", fake_run_command)

    code, lines = stop.collect_stop_report(keep_apps=True, timeout_sec=9)

    assert code == 0
    assert lines == [
        "==== Stop Local AI ====",
        "[1/3] Ollama not found; skipping model unload.",
        "[2/3] Stopping localai Docker containers...",
        "WARNING: docker compose down timed out after 9s",
        "[3/3] Leaving Docker Desktop and Ollama running (--keep-apps).",
        "",
        "Post-check loaded Ollama models:",
        "  Ollama not found.",
        "",
        "Local AI stop complete.",
    ]


def test_stop_closes_docker_and_ollama_by_default(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    ollama = Path("C:/missing/Ollama/ollama.exe")  # not found -> skip unload
    calls: list[tuple[str, ...]] = []

    def fake_run_command(
        args: list[str],
        *,
        cwd: Path,
        timeout_sec: int,
    ) -> CommandResult:
        calls.append(tuple(args))
        assert args[0] == "taskkill"
        image = args[2]
        # Docker Desktop is running; Ollama images are not.
        code = 0 if image == "Docker Desktop.exe" else 128
        return CommandResult(tuple(args), code, "", "")

    monkeypatch.setattr(stop, "ollama_path", lambda: ollama)
    monkeypatch.setattr(stop, "run_command", fake_run_command)

    code, lines = stop.collect_stop_report(keep_containers=True)

    assert code == 0
    # Every Ollama and Docker image is targeted for a forced kill.
    assert ("taskkill", "/IM", "ollama app.exe", "/F", "/T") in calls
    assert ("taskkill", "/IM", "Docker Desktop.exe", "/F", "/T") in calls
    assert lines == [
        "==== Stop Local AI ====",
        "[1/3] Ollama not found; skipping model unload.",
        "[2/3] Container stop skipped.",
        "[3/3] Closing Docker Desktop and Ollama...",
        "  Ollama not running.",
        "  Docker Desktop closed.",
        "",
        "Local AI stop complete.",
    ]
    # No post-check when we are closing Ollama outright.
    assert "Post-check loaded Ollama models:" not in lines


def test_stop_loaded_model_parser_uses_name_only(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class FakeResponse:
        def __enter__(self) -> FakeResponse:
            return self

        def __exit__(self, *args: Any) -> None:
            return None

        def read(self) -> bytes:
            return b'{"models":[{"name":"named:latest"},{"model":"ignored:latest"}]}'

    def fake_urlopen(url: str, *, timeout: int) -> FakeResponse:
        assert url == "http://localhost:11434/api/ps"
        assert timeout == 3
        return FakeResponse()

    monkeypatch.setattr(stop, "urlopen", fake_urlopen)

    assert stop.get_loaded_ollama_models() == ["named:latest"]
