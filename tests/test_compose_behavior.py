from __future__ import annotations

from pathlib import Path

import pytest

from localai import compose
from localai.ops import CommandResult
from localai.paths import REPO_ROOT


def _result(code: int = 0, stdout: str = "", stderr: str = "") -> CommandResult:
    return CommandResult(("docker",), code, stdout, stderr)


def test_compose_service_container_returns_first_id(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[tuple[tuple[str, ...], Path, int]] = []

    def fake(
        args: list[str], *, cwd: Path, env: dict[str, str], timeout_sec: int
    ) -> CommandResult:
        calls.append((tuple(args), cwd, timeout_sec))
        return _result(0, "abc123\n")

    monkeypatch.setattr(compose, "run_command", fake)
    assert compose.compose_service_container("open-webui") == "abc123"
    assert calls[0][0] == ("docker", "compose", "ps", "-q", "open-webui")
    assert calls[0][1] == REPO_ROOT


def test_compose_service_container_none_on_nonzero(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(compose, "run_command", lambda *a, **k: _result(1, ""))
    assert compose.compose_service_container("open-webui") is None


def test_compose_service_container_none_on_empty(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(compose, "run_command", lambda *a, **k: _result(0, "  \n"))
    assert compose.compose_service_container("open-webui") is None


def test_compose_service_status_parses_ndjson(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    line = (
        '{"Name":"localai-open-webui-1","Service":"open-webui","State":"running",'
        '"Status":"Up 2 minutes (healthy)","Health":"healthy"}'
    )
    monkeypatch.setattr(compose, "run_command", lambda *a, **k: _result(0, line + "\n"))
    status = compose.compose_service_status("open-webui")
    assert status is not None
    assert status.name == "localai-open-webui-1"
    assert status.state == "running"
    assert status.health == "healthy"


def test_compose_service_status_parses_array(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    arr = '[{"Name":"localai-searxng-1","State":"running","Status":"Up","Health":""}]'
    monkeypatch.setattr(compose, "run_command", lambda *a, **k: _result(0, arr))
    status = compose.compose_service_status("searxng")
    assert status is not None
    assert status.name == "localai-searxng-1"
    assert status.health is None


def test_compose_service_status_none_on_nonzero(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(compose, "run_command", lambda *a, **k: _result(1, ""))
    assert compose.compose_service_status("open-webui") is None


def test_compose_exec_builds_args(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[tuple[tuple[str, ...], Path, int]] = []

    def fake(
        args: list[str], *, cwd: Path, env: dict[str, str], timeout_sec: int
    ) -> CommandResult:
        calls.append((tuple(args), cwd, timeout_sec))
        return _result(0, "ok\n")

    monkeypatch.setattr(compose, "run_command", fake)
    result = compose.compose_exec(
        "open-webui", ["python", "-c", "print(1)"], timeout_sec=15
    )
    assert result.code == 0
    assert calls[0][0] == (
        "docker",
        "compose",
        "exec",
        "-T",
        "open-webui",
        "python",
        "-c",
        "print(1)",
    )
    assert calls[0][1] == REPO_ROOT
    assert calls[0][2] == 15


def test_service_volume_name_returns_volume_mount(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    mounts = (
        '[{"Type":"bind","Destination":"/etc/x","Name":"nope"},'
        '{"Type":"volume","Destination":"/app/backend/data",'
        '"Name":"localai_open-webui"}]'
    )

    def fake(
        args: list[str], *, cwd: Path, env: dict[str, str], timeout_sec: int
    ) -> CommandResult:
        if args[:3] == ["docker", "compose", "ps"]:
            return _result(0, "cid123\n")
        return _result(0, mounts)

    monkeypatch.setattr(compose, "run_command", fake)
    assert (
        compose.service_volume_name("open-webui", "/app/backend/data")
        == "localai_open-webui"
    )


def test_service_volume_name_none_for_bind_only(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    mounts = '[{"Type":"bind","Destination":"/app/backend/data","Name":"x"}]'

    def fake(
        args: list[str], *, cwd: Path, env: dict[str, str], timeout_sec: int
    ) -> CommandResult:
        if args[:3] == ["docker", "compose", "ps"]:
            return _result(0, "cid123\n")
        return _result(0, mounts)

    monkeypatch.setattr(compose, "run_command", fake)
    assert compose.service_volume_name("open-webui", "/app/backend/data") is None


def test_service_volume_name_none_when_no_container(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(compose, "run_command", lambda *a, **k: _result(1, ""))
    assert compose.service_volume_name("open-webui", "/app/backend/data") is None


def test_all_none_when_daemon_down(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        compose, "run_command", lambda *a, **k: _result(1, "", "daemon down")
    )
    assert compose.compose_service_container("open-webui") is None
    assert compose.compose_service_status("open-webui") is None
    assert compose.service_volume_name("open-webui", "/app/backend/data") is None
