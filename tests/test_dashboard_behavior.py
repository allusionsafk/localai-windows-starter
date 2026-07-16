from __future__ import annotations

import socket
import sys
import webbrowser
from collections.abc import Callable
from datetime import UTC
from typing import Any

import pytest
import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.routing import APIRoute

from localai import dashboard


def endpoint_for(app: FastAPI, path: str, method: str) -> Callable[..., Any]:
    for route in app.routes:
        if not isinstance(route, APIRoute):
            continue
        if route.path == path and route.methods is not None and method in route.methods:
            return route.endpoint
    raise AssertionError(f"route not found: {method} {path}")


def test_dashboard_manifest_exposes_legacy_control_center_surface() -> None:
    app = dashboard.create_app()
    endpoint = endpoint_for(app, "/api/dashboard", "GET")

    payload = endpoint()

    assert {check["id"] for check in payload["checks"]} >= {
        "start",
        "start-dry-run",
        "webbrain",
        "health",
        "perf",
        "power",
        "terminal",
        "anywhere",
        "firewall",
        "update-check",
        "update-now",
        "model-scout",
        "scout-prepare",
        "backup",
        "game-dry-run",
        "game-mode",
        "stop",
        "doctor",
        "cherry",
        "agent",
    }
    assert {link["id"] for link in payload["links"]} == {"chat", "image"}
    # Everything the legacy Control Center offered is ported; nothing pends.
    assert payload["pendingActions"] == []


def test_run_window_falls_back_without_pywebview(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setitem(sys.modules, "webview", None)
    assert dashboard._run_window("127.0.0.1", 8799) is False


def test_dashboard_runs_registered_python_check(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    fake_check = dashboard.DashboardCheck(
        "fake",
        "Fake",
        "Status",
        False,
        "localai fake",
        lambda: (0, ["[OK] Fake                    fine"]),
    )
    monkeypatch.setattr(dashboard, "CHECKS", {"fake": fake_check})
    app = dashboard.create_app()
    endpoint = endpoint_for(app, "/api/checks/{check_id}", "POST")

    payload = endpoint("fake")

    assert payload == {
        "id": "fake",
        "label": "Fake",
        "group": "Status",
        "mutates": False,
        "requiresConfirmation": False,
        "command": "localai fake",
        "exitCode": 0,
        "status": "ok",
        "lines": ["[OK] Fake                    fine"],
    }


def test_dashboard_rejects_unknown_check() -> None:
    app = dashboard.create_app()
    endpoint = endpoint_for(app, "/api/checks/{check_id}", "POST")

    with pytest.raises(HTTPException) as exc_info:
        endpoint("nope")
    assert exc_info.value.status_code == 404


def test_dashboard_requires_confirmation_for_mutating_check(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    called = False

    def fake_factory() -> tuple[int, list[str]]:
        nonlocal called
        called = True
        return 0, ["[OK] Fake                    changed"]

    fake_check = dashboard.DashboardCheck(
        "fake",
        "Fake",
        "Maintenance",
        True,
        "localai fake",
        fake_factory,
    )
    monkeypatch.setattr(dashboard, "CHECKS", {"fake": fake_check})
    app = dashboard.create_app()
    endpoint = endpoint_for(app, "/api/checks/{check_id}", "POST")

    with pytest.raises(HTTPException) as exc_info:
        endpoint("fake")
    assert exc_info.value.status_code == 409
    assert called is False

    payload = endpoint("fake", dashboard.RunCheckRequest(confirmed=True))
    assert called is True
    assert payload["status"] == "ok"
    assert payload["requiresConfirmation"] is True


def test_pick_folder_returns_none_without_pywebview(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setitem(sys.modules, "webview", None)
    assert dashboard._pick_folder() is None


def test_pick_folder_returns_none_without_native_window() -> None:
    # Whether pywebview is importable or not, no window is open under pytest.
    assert dashboard._pick_folder() is None


def test_agent_check_launches_console_in_picked_folder(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[tuple[list[str], Any]] = []

    def fake_popen(args: list[str], **kwargs: Any) -> None:
        calls.append((args, kwargs.get("cwd")))

    monkeypatch.setattr(dashboard, "_pick_folder", lambda: "C:\\proj")
    monkeypatch.setattr(dashboard.subprocess, "Popen", fake_popen)

    code, lines = dashboard._agent_check()

    assert code == 0
    ((args, cwd),) = calls
    assert args[0] == "pwsh"
    assert str(args[args.index("-File") + 1]).endswith("Start-AI-Agent.ps1")
    assert args[args.index("-Dir") + 1] == "C:\\proj"
    assert str(cwd) == "C:\\proj"
    assert any("opencode" in line for line in lines)


def test_agent_check_cancel_is_not_a_failure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def fail_popen(*args: Any, **kwargs: Any) -> None:
        raise AssertionError("Popen must not be called on cancel")

    monkeypatch.setattr(dashboard, "_pick_folder", lambda: "")
    monkeypatch.setattr(dashboard.subprocess, "Popen", fail_popen)

    code, lines = dashboard._agent_check()

    assert code == 0
    assert lines == ["Cancelled - no folder selected."]


def test_agent_check_fails_without_native_picker(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(dashboard, "_pick_folder", lambda: None)

    code, lines = dashboard._agent_check()

    assert code == 1
    assert lines[0].startswith("[FAIL]")
    assert dashboard.status_from_report(code, lines) == "fail"


def test_agent_check_warns_when_picker_already_open() -> None:
    assert dashboard._AGENT_PICKER_LOCK.acquire(blocking=False)
    try:
        code, lines = dashboard._agent_check()
    finally:
        dashboard._AGENT_PICKER_LOCK.release()

    assert code == 0
    assert lines[0].startswith("[WARN]")
    assert dashboard.status_from_report(code, lines) == "warn"


def test_scout_prepare_launches_console_prepare(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[list[str]] = []

    def fake_popen(args: list[str], **kwargs: Any) -> None:
        calls.append(args)

    monkeypatch.setattr(dashboard.subprocess, "Popen", fake_popen)

    code, lines = dashboard._scout_prepare_console()

    assert code == 0
    (args,) = calls
    assert args[1:] == ["-m", "localai", "model-scout", "--mode", "Prepare"]
    assert "python" in args[0].lower()
    assert any("Promote stays manual" in line for line in lines)
    # Pulling GBs must always be confirmed from the dashboard.
    assert dashboard.CHECKS["scout-prepare"].mutates is True


def test_game_mode_launches_console_not_in_request(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[list[str]] = []

    def fake_popen(args: list[str], **kwargs: Any) -> None:
        calls.append(args)

    monkeypatch.setattr(dashboard.subprocess, "Popen", fake_popen)

    code, lines = dashboard._game_mode_console()

    assert code == 0
    (args,) = calls
    assert args[1:] == ["-m", "localai", "game-mode", "--disable-warm-task"]
    assert "python" in args[0].lower()
    # Real Game Mode is heavy (WMI + wsl shutdown); it must not block the request.
    assert dashboard.CHECKS["game-mode"].factory is dashboard._game_mode_console
    assert dashboard.CHECKS["game-mode"].mutates is True


def test_dashboard_status_prefers_fail_then_warn() -> None:
    assert dashboard.status_from_report(0, ["[WARN] One"]) == "warn"
    assert dashboard.status_from_report(0, ["[FAIL] One"]) == "fail"
    assert dashboard.status_from_report(1, ["[OK] One"]) == "fail"


def test_serve_dashboard_opens_browser_when_pywebview_missing(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    opened: list[str] = []
    served: list[bool] = []
    monkeypatch.setattr(dashboard, "_run_window", lambda host, port: False)
    monkeypatch.setattr(webbrowser, "open", lambda url: opened.append(url))
    monkeypatch.setattr(uvicorn, "run", lambda *a, **k: served.append(True))

    dashboard.serve_dashboard("127.0.0.1", 8765, open_browser=False, window=True)

    assert opened == ["http://127.0.0.1:8765"]
    assert served == [True]


def test_serve_dashboard_skips_browser_when_window_opens(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    opened: list[str] = []
    served: list[bool] = []
    monkeypatch.setattr(dashboard, "_run_window", lambda host, port: True)
    monkeypatch.setattr(webbrowser, "open", lambda url: opened.append(url))
    monkeypatch.setattr(uvicorn, "run", lambda *a, **k: served.append(True))

    dashboard.serve_dashboard("127.0.0.1", 8765, open_browser=False, window=True)

    assert opened == []
    assert served == []


def test_bindable_port_skips_a_taken_port() -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as taken:
        taken.bind(("127.0.0.1", 0))
        port = taken.getsockname()[1]
        chosen = dashboard._bindable_port("127.0.0.1", port)
    assert chosen != port


def test_bindable_port_returns_a_free_port() -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        free = probe.getsockname()[1]
    assert dashboard._bindable_port("127.0.0.1", free) == free


def test_dashboard_alive_is_false_when_nothing_listens() -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    assert dashboard._dashboard_alive("127.0.0.1", port) is False


def test_runtime_reports_offline_engine(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(dashboard, "_ollama_ps", lambda: None)
    app = dashboard.create_app()
    endpoint = endpoint_for(app, "/api/runtime", "GET")

    payload = endpoint()

    assert payload["engine"] == "offline"
    assert payload["model"] is None
    assert payload["vramGb"] is None
    assert payload["gpuPercent"] is None
    assert payload["keepAliveMin"] is None
    assert payload["host"]
    assert payload["version"]


def test_runtime_reports_idle_engine_with_no_model(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(dashboard, "_ollama_ps", lambda: {"models": []})
    app = dashboard.create_app()
    endpoint = endpoint_for(app, "/api/runtime", "GET")

    payload = endpoint()

    assert payload["engine"] == "ok"
    assert payload["model"] is None


def test_runtime_reports_loaded_model_stats(monkeypatch: pytest.MonkeyPatch) -> None:
    from datetime import datetime

    fixed_now = datetime(2026, 7, 2, 11, 0, 0, tzinfo=UTC)
    monkeypatch.setattr(dashboard, "_utcnow", lambda: fixed_now)
    monkeypatch.setattr(
        dashboard,
        "_ollama_ps",
        lambda: {
            "models": [
                {
                    "name": "qwen2.5-grounded:latest",
                    "size": 10_200_547_328,
                    "size_vram": 10_200_547_328,
                    # Ollama emits nanosecond fractions; parser must cope.
                    "expires_at": "2026-07-02T11:30:00.123456789+00:00",
                }
            ]
        },
    )
    app = dashboard.create_app()
    endpoint = endpoint_for(app, "/api/runtime", "GET")

    payload = endpoint()

    assert payload["engine"] == "ok"
    assert payload["model"] == "qwen2.5-grounded:latest"
    assert payload["vramGb"] == 9.5
    assert payload["gpuPercent"] == 100
    assert payload["keepAliveMin"] == 30


def test_system_endpoint_returns_probe_payload(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    fake = {"cpuPercent": 12, "ramUsedGb": 10.5, "batteryPercent": 88}
    monkeypatch.setattr(dashboard, "collect_system", lambda: fake)
    app = dashboard.create_app()
    endpoint = endpoint_for(app, "/api/system", "GET")

    assert endpoint() == fake


def test_keep_alive_minutes_never_negative() -> None:
    assert dashboard._keep_alive_minutes("2000-01-01T00:00:00+00:00") == 0


def test_keep_alive_minutes_rejects_garbage() -> None:
    assert dashboard._keep_alive_minutes("not-a-date") is None


def test_console_python_swaps_pythonw_for_console_sibling(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Any
) -> None:
    pyw = tmp_path / "pythonw.exe"
    py = tmp_path / "python.exe"
    pyw.write_bytes(b"")
    py.write_bytes(b"")
    monkeypatch.setattr(dashboard.sys, "executable", str(pyw))
    assert dashboard._console_python() == str(py)

    py.unlink()  # no console sibling -> fall back to what we have
    assert dashboard._console_python() == str(pyw)


def _patch_warm_state(monkeypatch: pytest.MonkeyPatch, tmp_path: Any) -> None:
    from localai import warm

    state = tmp_path / "warm-model.json"
    monkeypatch.setattr(warm, "warm_state_path", lambda: state)


def test_models_endpoint_lists_tags_with_default_selected(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Any
) -> None:
    from localai import warm

    default = warm.read_default_model()
    _patch_warm_state(monkeypatch, tmp_path)
    monkeypatch.setattr(
        dashboard, "_ollama_tags", lambda: ["qwen3-grounded", default]
    )
    app = dashboard.create_app()
    endpoint = endpoint_for(app, "/api/models", "GET")

    payload = endpoint()

    assert payload["source"] == "ollama"
    assert payload["default"] == default
    assert payload["selected"] == default
    assert payload["models"][0] == default
    assert "qwen3-grounded" in payload["models"]


def test_models_endpoint_serves_cache_when_engine_down(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Any
) -> None:
    from localai import warm

    _patch_warm_state(monkeypatch, tmp_path)
    warm.write_known_models(["cached-model:latest"])
    warm.write_warm_model_override("cached-model:latest")
    monkeypatch.setattr(dashboard, "_ollama_tags", lambda: None)
    app = dashboard.create_app()
    endpoint = endpoint_for(app, "/api/models", "GET")

    payload = endpoint()

    assert payload["source"] == "cache"
    assert payload["selected"] == "cached-model:latest"
    assert "cached-model:latest" in payload["models"]


def test_set_warm_model_persists_then_clears(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Any
) -> None:
    from localai import warm

    _patch_warm_state(monkeypatch, tmp_path)
    monkeypatch.setattr(dashboard, "_ollama_tags", lambda: ["deep-thinking-qwen3.6"])
    app = dashboard.create_app()
    set_endpoint = endpoint_for(app, "/api/warm-model", "POST")

    payload = set_endpoint(dashboard.WarmModelRequest(model="deep-thinking-qwen3.6"))
    assert payload["selected"] == "deep-thinking-qwen3.6"
    assert warm.read_warm_model_override() == "deep-thinking-qwen3.6"

    payload = set_endpoint(dashboard.WarmModelRequest(model=None))
    # Clearing the override falls back to whatever DEFAULT_MODELS is in compose.
    assert payload["selected"] == warm.read_default_model()
    assert warm.read_warm_model_override() is None


def test_set_warm_model_rejects_garbage_tags(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Any
) -> None:
    _patch_warm_state(monkeypatch, tmp_path)
    app = dashboard.create_app()
    set_endpoint = endpoint_for(app, "/api/warm-model", "POST")

    with pytest.raises(HTTPException) as exc_info:
        set_endpoint(dashboard.WarmModelRequest(model="bad model; rm -rf"))
    assert exc_info.value.status_code == 400
