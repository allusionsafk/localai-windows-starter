from __future__ import annotations

from pathlib import Path
from urllib.error import URLError

import pytest

from localai import game_mode
from localai.ops import CommandResult
from localai.paths import REPO_ROOT


def test_game_mode_dry_run_report_lists_every_cleanup_action(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    ollama = Path("C:/fake/Ollama/ollama.exe")
    original_exists = Path.exists

    def fake_exists(path: Path) -> bool:
        if path == ollama:
            return True
        return original_exists(path)

    def fake_get_loaded_ollama_models(
        actual_ollama: Path,
        timeout_sec: int,
    ) -> tuple[list[str], list[str]]:
        assert actual_ollama == ollama
        assert timeout_sec == 7
        return ["qwen2.5-grounded:latest"], []

    def fake_get_comfyui_processes() -> tuple[list[game_mode.ProcessInfo], list[str]]:
        return [
            game_mode.ProcessInfo(
                pid=1234,
                name="python.exe",
                command_line=r"python C:\ComfyUI\main.py",
            )
        ], []

    monkeypatch.setattr(game_mode, "ollama_path", lambda: ollama)
    monkeypatch.setattr(Path, "exists", fake_exists)
    monkeypatch.setattr(
        game_mode,
        "get_loaded_ollama_models",
        fake_get_loaded_ollama_models,
    )
    monkeypatch.setattr(game_mode, "get_comfyui_processes", fake_get_comfyui_processes)
    monkeypatch.setattr(game_mode, "docker_path", lambda: "docker")

    code, lines = game_mode.collect_game_mode_report(
        dry_run=True,
        disable_warm_task=True,
        ollama_timeout_sec=7,
    )

    assert code == 0
    assert lines[:3] == [
        "==== AI game mode cleanup ====",
        "[dry-run] No models, containers, tasks, or WSL processes will be stopped.",
        "[0/4] Disabling AI-Warm logon preload...",
    ]
    assert "  would disable scheduled task AI-Warm" in lines
    assert "  would ollama stop qwen2.5-grounded:latest" in lines
    assert "  would stop PID 1234 python.exe" in lines
    assert any(
        line.startswith("  would run: docker compose -f ")
        and line.endswith("docker-compose.yml down")
        for line in lines
    )
    assert "  would run: wsl --shutdown" in lines
    assert lines[-3:] == [
        "  qwen2.5-grounded:latest",
        "",
        "Game mode cleanup complete. Run Start-LocalAI.bat when you want Open "
        "WebUI back.",
    ]


def test_game_mode_keep_flags_skip_docker_and_wsl(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    missing_ollama = Path("C:/fake/Ollama/ollama.exe")

    monkeypatch.setattr(game_mode, "ollama_path", lambda: missing_ollama)
    monkeypatch.setattr(game_mode, "get_comfyui_processes", lambda: ([], []))

    code, lines = game_mode.collect_game_mode_report(
        dry_run=True,
        keep_docker=True,
        keep_wsl=True,
    )

    assert code == 0
    assert "[1/4] Ollama not found; skipping." in lines
    assert "[3/4] Docker cleanup skipped." in lines
    assert "[4/4] WSL shutdown skipped." in lines
    assert "  Ollama not found." in lines


def test_get_loaded_ollama_models_falls_back_to_ollama_ps(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    ollama = Path("C:/fake/Ollama/ollama.exe")

    def fake_urlopen(url: str, *, timeout: int) -> object:
        assert url == "http://localhost:11434/api/ps"
        assert timeout == 5
        raise URLError("offline")

    def fake_run_command(
        args: list[str],
        *,
        cwd: Path,
        timeout_sec: int,
    ) -> CommandResult:
        assert args == [str(ollama), "ps"]
        assert cwd == REPO_ROOT
        assert timeout_sec == 11
        return CommandResult(
            tuple(args),
            0,
            "NAME ID SIZE PROCESSOR UNTIL\nqwen:latest abc 1 GB 100% GPU 4m\n",
            "",
        )

    monkeypatch.setattr(game_mode, "urlopen", fake_urlopen)
    monkeypatch.setattr(game_mode, "run_command", fake_run_command)

    models, messages = game_mode.get_loaded_ollama_models(ollama, timeout_sec=11)

    assert models == ["qwen:latest"]
    assert messages == []
