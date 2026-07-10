from __future__ import annotations

import time
from pathlib import Path

import pytest

from localai import start
from localai.ops import CommandResult


def _patch_live(
    monkeypatch: pytest.MonkeyPatch,
    *,
    ollama: bool = True,
    docker: bool = True,
    compose_code: int = 0,
    alias: tuple[int, list[str]] = (0, ["[alias] ok"]),
    warm: tuple[int, list[str]] = (0, ["[warm] ok"]),
    anywhere: tuple[int, list[str]] = (0, ["[anywhere] ok"]),
    health: tuple[int, list[str]] = (0, ["[health] ok"]),
    tailscale: bool = True,
) -> None:
    """Stub every external touchpoint so the live orchestration can be unit-tested."""
    monkeypatch.setattr(start, "_ollama_api_ready", lambda *a, **k: ollama)
    monkeypatch.setattr(start, "_docker_ready", lambda *a, **k: docker)
    monkeypatch.setattr(start, "_launch_detached", lambda *a, **k: True)
    monkeypatch.setattr(time, "sleep", lambda *a, **k: None)
    monkeypatch.setattr(start, "_open_browser", lambda *a, **k: True)
    monkeypatch.setattr(
        start,
        "run_command",
        lambda *a, **k: CommandResult(("docker",), compose_code, "", ""),
    )
    monkeypatch.setattr(start, "collect_model_aliases_report", lambda *a, **k: alias)
    monkeypatch.setattr(start, "collect_warm_report", lambda *a, **k: warm)
    monkeypatch.setattr(start, "collect_anywhere_report", lambda *a, **k: anywhere)
    monkeypatch.setattr(
        start, "resolve_tailscale", lambda: Path("ts.exe") if tailscale else None
    )
    monkeypatch.setattr(start, "collect_health_report", lambda *a, **k: health)


def test_start_requests_lenient_alias_refresh(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # On a clean box the alias sources are absent; start must ask model-aliases to
    # treat that as non-fatal so the stack still comes up (audit finding 2).
    _patch_live(monkeypatch)
    captured: dict[str, object] = {}

    def spy(*_a: object, **kwargs: object) -> tuple[int, list[str]]:
        captured.update(kwargs)
        return (0, ["[alias] ok"])

    monkeypatch.setattr(start, "collect_model_aliases_report", spy)
    code, _ = start.collect_start_report()

    assert code == 0
    assert captured.get("lenient") is True


def test_start_live_happy_path(monkeypatch: pytest.MonkeyPatch) -> None:
    _patch_live(monkeypatch)
    code, lines = start.collect_start_report()

    assert code == 0
    for header in (
        "[1/9] Ollama app",
        "[5/9] Open WebUI + SearXNG + Kokoro",
        "[9/9] Health check and final warm",
    ):
        assert header in lines
    assert lines[-1] == "Local AI is UP: this PC -> http://localhost:3000"


def test_start_live_passes_warm_model_override_to_both_warm_steps(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[dict[str, object]] = []

    def capture_warm(*args: object, **kwargs: object) -> tuple[int, list[str]]:
        calls.append(dict(kwargs))
        return 0, ["[warm] ok"]

    _patch_live(monkeypatch)
    monkeypatch.setattr(start, "collect_warm_report", capture_warm)
    monkeypatch.setattr(
        start, "read_warm_model_override", lambda: "deep-thinking-qwen3.6"
    )

    code, _ = start.collect_start_report()

    assert code == 0
    assert len(calls) == 2
    for kwargs in calls:
        assert kwargs["model"] == "deep-thinking-qwen3.6"
        assert kwargs["prefer_target"] is True


def test_start_live_without_override_keeps_preserve_semantics(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[dict[str, object]] = []

    def capture_warm(*args: object, **kwargs: object) -> tuple[int, list[str]]:
        calls.append(dict(kwargs))
        return 0, ["[warm] ok"]

    _patch_live(monkeypatch)
    monkeypatch.setattr(start, "collect_warm_report", capture_warm)
    monkeypatch.setattr(start, "read_warm_model_override", lambda: None)

    code, _ = start.collect_start_report()

    assert code == 0
    assert len(calls) == 2
    for kwargs in calls:
        assert kwargs["model"] is None
        assert kwargs["prefer_target"] is False


def test_start_live_fails_when_ollama_never_ready(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _patch_live(monkeypatch, ollama=False)
    code, lines = start.collect_start_report()

    assert code == 1
    assert any("Ollama did not become reachable" in line for line in lines)


def test_start_live_fails_when_compose_up_fails(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _patch_live(monkeypatch, compose_code=1)
    code, lines = start.collect_start_report()

    assert code == 1
    assert any("docker compose up -d failed" in line for line in lines)


def test_start_live_health_failure_is_fatal(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _patch_live(monkeypatch, health=(1, ["health bad"]))
    code, lines = start.collect_start_report()

    assert code == 1
    assert any("health check failed" in line for line in lines)


def test_start_live_tailscale_failure_is_non_fatal(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _patch_live(monkeypatch, anywhere=(1, ["serve failed"]))
    code, lines = start.collect_start_report()

    assert code == 0
    assert any("Tailscale Serve reported a problem" in line for line in lines)


def test_start_live_skips_remote_when_tailscale_absent(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # A friend without Tailscale gets one calm line, not a wall of FAILs.
    _patch_live(monkeypatch, tailscale=False, anywhere=(1, ["serve failed"]))
    code, lines = start.collect_start_report()

    assert code == 0
    assert any("Remote access (optional)" in line for line in lines)
    assert not any("reported a problem" in line for line in lines)
    assert not any("serve failed" in line for line in lines)


def test_start_dry_run_preserves_batch_launcher_order() -> None:
    code, lines = start.collect_start_report(dry_run=True)

    assert code == 0
    assert lines[:4] == [
        "==== localai start dry-run ====",
        "[dry-run] No processes, containers, Tailscale routes, models, or browser "
        "windows will be started.",
        "Starting your local AI...",
        "[1/9] Ollama app",
    ]
    assert "[5/9] Open WebUI + SearXNG + Kokoro" in lines
    assert "  would run: localai model-aliases" in lines
    assert "[9/9] Health check and final warm" in lines
    assert "  would open: http://localhost:3000" in lines
    assert lines[-1] == "Local AI start dry-run complete."


def test_start_dry_run_honors_no_open() -> None:
    code, lines = start.collect_start_report(dry_run=True, no_open=True)

    assert code == 0
    assert "  Browser launch skipped because --no-open was passed." in lines
    assert "  would open: http://localhost:3000" not in lines
