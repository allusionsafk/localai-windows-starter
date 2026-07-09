from __future__ import annotations

from collections.abc import Callable
from typing import Any

import pytest
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


def test_api_scout_returns_cached_groups(monkeypatch: pytest.MonkeyPatch) -> None:
    fake = {"generated": "2026-07-08 12:00", "groups": {"chat": {"top": {"name": "x"}}}}
    monkeypatch.setattr(dashboard, "read_scout_groups", lambda: fake)
    app = dashboard.create_app()

    payload = endpoint_for(app, "/api/scout", "GET")()

    assert payload == fake


def test_api_scout_absent_cache_is_null(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(dashboard, "read_scout_groups", lambda: None)
    app = dashboard.create_app()

    payload = endpoint_for(app, "/api/scout", "GET")()

    assert payload == {"generated": None, "groups": None}


def test_api_scout_refresh_runs_scout(monkeypatch: pytest.MonkeyPatch) -> None:
    ran: dict[str, Any] = {}

    def fake_report(**kwargs: Any) -> tuple[int, list[str]]:
        ran.update(kwargs)
        return 0, ["[Chat]", "  TOP  x"]

    monkeypatch.setattr(dashboard, "collect_model_scout_report", fake_report)
    monkeypatch.setattr(
        dashboard,
        "read_scout_groups",
        lambda: {"generated": "t", "groups": {"chat": {}}},
    )
    app = dashboard.create_app()

    payload = endpoint_for(app, "/api/scout/refresh", "POST")()

    assert ran["mode"] == "Scout"
    assert payload["groups"] == {"chat": {}}
    assert payload["status"] == "ok"


def test_api_scout_prepare_requires_confirmation() -> None:
    app = dashboard.create_app()
    endpoint = endpoint_for(app, "/api/scout/prepare", "POST")

    with pytest.raises(HTTPException) as exc_info:
        endpoint(dashboard.ScoutPrepareRequest(category="coding", confirmed=False))
    assert exc_info.value.status_code == 409


def test_api_scout_prepare_rejects_unknown_category() -> None:
    app = dashboard.create_app()
    endpoint = endpoint_for(app, "/api/scout/prepare", "POST")

    with pytest.raises(HTTPException) as exc_info:
        endpoint(dashboard.ScoutPrepareRequest(category="nope", confirmed=True))
    assert exc_info.value.status_code == 400


def test_api_scout_prepare_launches_console_with_category(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[list[str]] = []
    monkeypatch.setattr(
        dashboard.subprocess, "Popen", lambda args, **kw: calls.append(args)
    )
    app = dashboard.create_app()
    endpoint = endpoint_for(app, "/api/scout/prepare", "POST")

    payload = endpoint(dashboard.ScoutPrepareRequest(category="coding", confirmed=True))

    (args,) = calls
    assert args[1:] == [
        "-m",
        "localai",
        "model-scout",
        "--mode",
        "Prepare",
        "--category",
        "coding",
    ]
    assert payload["category"] == "coding"
    assert payload["status"] == "ok"
