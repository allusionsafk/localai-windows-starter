from __future__ import annotations

from collections.abc import Sequence
from pathlib import Path

import pytest

from localai import anywhere
from localai.ops import CommandResult


def test_get_serve_status_parses_proxy_targets_from_json(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    payload = (
        '{"Web":{"host.tailnet.ts.net:443":{"Handlers":'
        '{"/":{"Proxy":"http://127.0.0.1:3000"}}}}}'
    )

    def fake_run_command(
        args: list[str], *, timeout_sec: int
    ) -> CommandResult:
        assert args[-3:] == ["serve", "status", "--json"]
        return CommandResult(tuple(args), 0, payload, "")

    monkeypatch.setattr(anywhere, "run_command", fake_run_command)

    status = anywhere.get_serve_status(Path("tailscale.exe"))

    assert status.code == 0
    assert status.proxy_targets == ("http://127.0.0.1:3000",)
    assert status.proxies_to_port(3000)
    assert not status.proxies_to_port(8080)


def test_get_serve_status_ignores_mappings_for_other_ports(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Regression guard for the old broad `:port` text match: a Serve config
    # fronting an unrelated port must not be reported as proxying ours.
    payload = (
        '{"Web":{"host.tailnet.ts.net:443":{"Handlers":'
        '{"/":{"Proxy":"http://127.0.0.1:9999"}}}}}'
    )

    def fake_run_command(
        args: list[str], *, timeout_sec: int
    ) -> CommandResult:
        return CommandResult(tuple(args), 0, payload, "")

    monkeypatch.setattr(anywhere, "run_command", fake_run_command)

    status = anywhere.get_serve_status(Path("tailscale.exe"))

    assert not status.proxies_to_port(3000)


def test_get_serve_status_handles_no_serve_config(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def fake_run_command(
        args: list[str], *, timeout_sec: int
    ) -> CommandResult:
        return CommandResult(tuple(args), 0, "{}", "")

    monkeypatch.setattr(anywhere, "run_command", fake_run_command)

    status = anywhere.get_serve_status(Path("tailscale.exe"))

    assert status.proxy_targets == ()
    assert not status.proxies_to_port(3000)


def test_get_serve_status_handles_command_failure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def fake_run_command(
        args: list[str], *, timeout_sec: int
    ) -> CommandResult:
        return CommandResult(tuple(args), 1, "", "Tailscale is not running")

    monkeypatch.setattr(anywhere, "run_command", fake_run_command)

    status = anywhere.get_serve_status(Path("tailscale.exe"))

    assert status.code == 1
    assert status.proxy_targets == ()
    assert "not running" in status.text


def test_get_serve_status_handles_malformed_json(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def fake_run_command(
        args: list[str], *, timeout_sec: int
    ) -> CommandResult:
        return CommandResult(tuple(args), 0, "not json", "")

    monkeypatch.setattr(anywhere, "run_command", fake_run_command)

    status = anywhere.get_serve_status(Path("tailscale.exe"))

    assert status.proxy_targets == ()


def _setup_anywhere(
    monkeypatch: pytest.MonkeyPatch,
    *,
    connected: bool = True,
    owui: int = 200,
    serve_code: int = 0,
    serve_proxies: bool = True,
    funnel_text: str = "(tailnet only)",
) -> None:
    monkeypatch.setattr(
        anywhere, "read_text_if_exists", lambda p: "127.0.0.1:3000:8080"
    )
    monkeypatch.setattr(anywhere, "http_code", lambda url, *, timeout_sec: owui)
    monkeypatch.setattr(
        anywhere, "resolve_tailscale", lambda: Path("tailscale.exe")
    )
    monkeypatch.setattr(
        anywhere,
        "get_tailscale_self",
        lambda ts, port: anywhere.TailscaleSelf(
            connected, "online", "https://x.ts.net", "x.ts.net", ("100.1.2.3",)
        ),
    )
    targets = ("http://127.0.0.1:3000",) if serve_proxies else ()
    monkeypatch.setattr(
        anywhere, "get_serve_status", lambda ts: anywhere.ServeStatus(0, "s", targets)
    )

    def fake_run_command(
        args: Sequence[str],
        *,
        cwd: object = None,
        env: object = None,
        timeout_sec: object = None,
    ) -> CommandResult:
        a = list(args)
        if "serve" in a:
            code = serve_code
            return CommandResult(tuple(a), code, "consent" if code else "", "")
        if "funnel" in a:
            return CommandResult(tuple(a), 0, funnel_text, "")
        return CommandResult(tuple(a), 0, "", "")

    monkeypatch.setattr(anywhere, "run_command", fake_run_command)


def test_anywhere_apply_not_signed_in_exit_11(monkeypatch: pytest.MonkeyPatch) -> None:
    _setup_anywhere(monkeypatch, connected=False)
    code, _ = anywhere.collect_anywhere_report(apply=True)
    assert code == 11


def test_anywhere_apply_backend_down_exit_12(monkeypatch: pytest.MonkeyPatch) -> None:
    _setup_anywhere(monkeypatch, owui=0)
    code, _ = anywhere.collect_anywhere_report(apply=True)
    assert code == 12


def test_anywhere_apply_serve_failure_exit_13(monkeypatch: pytest.MonkeyPatch) -> None:
    _setup_anywhere(monkeypatch, serve_code=1, serve_proxies=False)
    code, _ = anywhere.collect_anywhere_report(apply=True)
    assert code == 13


def test_anywhere_apply_success_exit_0(monkeypatch: pytest.MonkeyPatch) -> None:
    _setup_anywhere(monkeypatch)
    code, _ = anywhere.collect_anywhere_report(apply=True)
    assert code == 0


def test_anywhere_audit_backend_down_is_warn_exit_0(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _setup_anywhere(monkeypatch, owui=0)
    code, _ = anywhere.collect_anywhere_report(apply=False)
    assert code == 0
