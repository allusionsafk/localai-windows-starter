from __future__ import annotations

from datetime import datetime

import pytest

from localai import compose, health
from localai.ops import CommandResult


def test_health_status_line_matches_legacy_width() -> None:
    assert (
        health.format_status_line("OK", "Open WebUI bind", "localhost-only")
        == "[OK] Open WebUI bind          localhost-only"
    )


def test_health_model_config_matches_compose_contract() -> None:
    lines: list[str] = []

    def add_line(status: str, name: str, detail: str) -> None:
        lines.append(health.format_status_line(status, name, detail))

    compose = """
    - DEFAULT_MODELS=qwen2.5-grounded
    - TASK_MODEL=
    - DEFAULT_MODEL_PARAMS={"stream_response":true,"keep_alive":"30m"}
    - ENABLE_MEMORIES=True
    """

    health.check_model_config(add_line, compose, "qwen2.5-grounded", "")

    assert lines == [
        "[OK] Default model            qwen2.5-grounded",
        "[OK] Task model               blank; tasks use the current chat model",
        "[OK] Render safety            stream_response=true; request keep_alive=30m",
        "[OK] Open WebUI memories      enabled; think-light uses per-model think=false",
    ]


def test_health_docker_down_reports_single_daemon_failure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    lines: list[tuple[str, str, str]] = []

    def add_line(status: str, name: str, detail: str) -> None:
        lines.append((status, name, detail))

    def fake_run_command(
        args: list[str],
        *,
        cwd: object,
        timeout_sec: int,
    ) -> CommandResult:
        assert args[:2] == ["docker", "info"]
        assert timeout_sec == 20
        return CommandResult(tuple(args), 1, "", "docker down")

    monkeypatch.setattr(health, "run_command", fake_run_command)

    health.check_docker_containers(add_line)

    assert lines == [("FAIL", "Docker", "daemon not reachable")]


def test_health_docker_up_reports_per_service_status(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    lines: list[tuple[str, str, str]] = []

    def add_line(status: str, name: str, detail: str) -> None:
        lines.append((status, name, detail))

    def fake_run_command(
        args: list[str], *, cwd: object, timeout_sec: int
    ) -> CommandResult:
        assert args[:2] == ["docker", "info"]
        return CommandResult(tuple(args), 0, "27.0\n", "")

    statuses = {
        "open-webui": compose.ServiceStatus(
            "localai-open-webui-1", "running", "Up (healthy)", "healthy"
        ),
        "searxng": compose.ServiceStatus("localai-searxng-1", "running", "Up", None),
        "kokoro": None,
    }
    monkeypatch.setattr(health, "run_command", fake_run_command)
    monkeypatch.setattr(
        compose, "compose_service_status", lambda service, **k: statuses[service]
    )

    health.check_docker_containers(add_line)

    assert lines == [
        ("OK", "localai-open-webui-1", "Up (healthy)"),
        ("OK", "localai-searxng-1", "Up"),
        ("FAIL", "kokoro", "not running"),
    ]


def test_health_collect_summary_uses_fail_exit(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def ok_check(add_line: health.AddLine, *args: object, **kwargs: object) -> None:
        add_line("OK", "One", "fine")

    def fail_check(add_line: health.AddLine, *args: object, **kwargs: object) -> None:
        add_line("FAIL", "Two", "broken")

    monkeypatch.setattr(health, "read_compose_text", lambda: "")
    monkeypatch.setattr(health, "read_default_model", lambda _text: "unknown")
    monkeypatch.setattr(health, "read_task_model", lambda _text: None)
    monkeypatch.setattr(health, "check_docker_containers", fail_check)
    monkeypatch.setattr(health, "check_open_webui", fail_check)
    monkeypatch.setattr(health, "check_tailscale", ok_check)
    monkeypatch.setattr(health, "check_model_config", ok_check)
    monkeypatch.setattr(health, "check_open_webui_thinking", ok_check)
    monkeypatch.setattr(health, "check_terminal_launchers", ok_check)
    monkeypatch.setattr(health, "check_terminal_commands", ok_check)
    monkeypatch.setattr(health, "check_node_smoke", ok_check)
    monkeypatch.setattr(health, "check_nanobrowser", ok_check)
    monkeypatch.setattr(health, "check_cherry_agent", ok_check)
    monkeypatch.setattr(health, "check_ollama", ok_check)
    monkeypatch.setattr(health, "check_open_webui_reaches_ollama", ok_check)
    monkeypatch.setattr(health, "check_tiny_inference", ok_check)
    monkeypatch.setattr(health, "check_searxng", ok_check)
    monkeypatch.setattr(health, "check_kokoro", ok_check)
    monkeypatch.setattr(health, "check_image_studio", ok_check)
    monkeypatch.setattr(health, "check_gpu_memory", ok_check)
    monkeypatch.setattr(health, "check_firewall", ok_check)
    monkeypatch.setattr(health, "check_git_secret_guard", ok_check)

    code, lines = health.collect_health_report(
        now=datetime(2026, 6, 21, 21, 0, 0),
    )
    assert code == 1
    assert lines[0] == "==== localai health ====  2026-06-21 21:00:00"
    assert lines[-1] == "Summary: 18 OK, 0 WARN, 2 FAIL"


def test_health_thinking_unsupported_schema_warns(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    lines: list[tuple[str, str, str]] = []
    monkeypatch.setattr(
        compose,
        "compose_exec",
        lambda *a, **k: CommandResult(("x",), 2, "SCHEMA: no model table", ""),
    )
    health.check_open_webui_thinking(lambda s, n, d: lines.append((s, n, d)))
    assert lines == [
        (
            "WARN",
            "Open WebUI thinking",
            "unsupported Open WebUI schema; skipped think-light check",
        )
    ]


def test_check_open_webui_reaches_ollama_classifies(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    lines: list[tuple[str, str, str]] = []
    record = lambda s, n, d: lines.append((s, n, d))  # noqa: E731

    monkeypatch.setattr(compose, "compose_service_status", lambda *a, **k: None)
    health.check_open_webui_reaches_ollama(record)
    assert lines[0][0] == "WARN"

    lines.clear()
    running = compose.ServiceStatus("c", "running", "Up", "healthy")
    monkeypatch.setattr(compose, "compose_service_status", lambda *a, **k: running)
    monkeypatch.setattr(
        health,
        "smoke_open_webui_reaches_ollama",
        lambda **k: health.SmokeResult(True, "3 models"),
    )
    health.check_open_webui_reaches_ollama(record)
    assert lines[0][0] == "OK"

    lines.clear()
    monkeypatch.setattr(
        health,
        "smoke_open_webui_reaches_ollama",
        lambda **k: health.SmokeResult(False, "refused"),
    )
    health.check_open_webui_reaches_ollama(record)
    assert lines[0] == ("FAIL", "Open WebUI->Ollama", "refused")


def test_check_tiny_inference_classifies(monkeypatch: pytest.MonkeyPatch) -> None:
    lines: list[tuple[str, str, str]] = []
    record = lambda s, n, d: lines.append((s, n, d))  # noqa: E731

    monkeypatch.setattr(
        health,
        "smoke_tiny_inference",
        lambda model, **k: health.SmokeResult(True, "ok"),
    )
    health.check_tiny_inference(record, "m")
    assert lines[0][0] == "OK"

    lines.clear()
    monkeypatch.setattr(
        health,
        "smoke_tiny_inference",
        lambda model, **k: health.SmokeResult(False, "down"),
    )
    health.check_tiny_inference(record, "m")
    assert lines[0][0] == "WARN"


def test_parse_ollama_list_names_adds_latest_alias() -> None:
    text = "NAME ID SIZE MODIFIED\nqwen:latest abc 1 GB today\nbare abc 1 GB today\n"

    assert health.parse_ollama_list_names(text) == {
        "qwen:latest",
        "qwen",
        "bare",
    }


# ------------------------------------------------- P1.4: no WARN wall on a friend box


def test_optional_artifact_checks_skip_silently_when_absent(
    monkeypatch: pytest.MonkeyPatch, tmp_path: object
) -> None:
    """P1.4: the private test harnesses and launchers (Cherry MCP, MCP bundle,
    nanobrowser, Cherry agent, terminal launchers/commands, image studio) are not
    shipped in the public repo. On a friend box each such check must emit NOTHING
    -- a clean self-test, not a wall of WARNs about files they were never given."""
    import pathlib

    empty = pathlib.Path(str(tmp_path))
    monkeypatch.setattr(health, "repo_path", lambda name: empty / name)  # none exist
    monkeypatch.setattr(health, "tcp_open", lambda *a, **k: False)  # no ComfyUI
    monkeypatch.setenv("USERPROFILE", str(empty))  # no ~/.local/bin, no ~/imageai
    monkeypatch.setenv("PROGRAMFILES", str(empty))  # no node.exe
    monkeypatch.setenv("LOCALAPPDATA", str(empty))

    lines: list[tuple[str, str, str]] = []
    rec = lambda s, n, d: lines.append((s, n, d))  # noqa: E731

    health.check_node_smoke(rec, "Cherry MCP", "test-filesystem-mcp.mjs", "x", "y")
    health.check_node_smoke(rec, "MCP bundle", "test-mcp-bundle.mjs", "x", "y")
    health.check_nanobrowser(rec, "qwen3.5:9b-32k")
    health.check_cherry_agent(rec)
    health.check_terminal_launchers(rec)
    health.check_terminal_commands(rec)
    health.check_image_studio(rec)

    assert lines == []  # every optional check stayed silent


def test_nanobrowser_present_but_failing_still_warns(
    monkeypatch: pytest.MonkeyPatch, tmp_path: object
) -> None:
    """Don't weaken the maintainer box: when the harness IS present, a real failure
    must still surface as a WARN (silence is only for the unshipped case)."""
    import pathlib

    root = pathlib.Path(str(tmp_path))
    (root / "test-browser-ai-provider.ps1").write_text("stub", encoding="utf-8")
    monkeypatch.setattr(health, "repo_path", lambda name: root / name)
    monkeypatch.setattr(
        health, "run_command", lambda *a, **k: CommandResult(("x",), 1, "boom", "")
    )

    lines: list[tuple[str, str, str]] = []
    health.check_nanobrowser(lambda s, n, d: lines.append((s, n, d)), "m")

    assert lines and lines[0][0] == "WARN"


def test_terminal_launchers_present_reports_ok_partial_warns(
    monkeypatch: pytest.MonkeyPatch, tmp_path: object
) -> None:
    """Maintainer contract: all launchers present -> OK; some missing -> WARN;
    none present (friend box) -> silent."""
    import pathlib

    root = pathlib.Path(str(tmp_path))
    names = (
        "Start-TerminalAI.ps1",
        "Stop-LocalAI.ps1",
        "Stop-AI-For-Gaming.ps1",
        "Terminal-Code.bat",
        "Terminal-DeepCode.bat",
        "Stop-LocalAI.bat",
        "AI-Game-Mode.bat",
    )
    monkeypatch.setattr(health, "repo_path", lambda name: root / name)

    # all present -> OK
    for name in names:
        (root / name).write_text("x", encoding="utf-8")
    lines: list[tuple[str, str, str]] = []
    health.check_terminal_launchers(lambda s, n, d: lines.append((s, n, d)))
    assert lines and lines[0][0] == "OK"

    # one missing -> WARN (a real gap on a box that has the rest)
    (root / names[0]).unlink()
    lines.clear()
    health.check_terminal_launchers(lambda s, n, d: lines.append((s, n, d)))
    assert lines and lines[0][0] == "WARN"

    # none present -> silent
    for name in names[1:]:
        (root / name).unlink()
    lines.clear()
    health.check_terminal_launchers(lambda s, n, d: lines.append((s, n, d)))
    assert lines == []
