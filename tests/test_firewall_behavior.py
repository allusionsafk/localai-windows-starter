from __future__ import annotations

from datetime import datetime
from pathlib import Path

import pytest

from localai import firewall
from localai.ops import CommandResult
from localai.paths import REPO_ROOT


def test_firewall_report_ok_when_physical_block_shadows_allows(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    block_rule = firewall.FirewallRule(
        rule_name=firewall.PHYSICAL_BLOCK_RULE_NAME,
        enabled="Yes",
        direction="In",
        action="Block",
        protocol="TCP",
        profiles="Domain,Private,Public",
        remote_ip="Any",
        local_port="3000,8888,11434,8080,8880,8188",
    )
    inbound_rows = [
        firewall.PortMatch(
            port=3000,
            rule_name="Third-party dev server",
            profiles="Private",
            remote_ip="Any",
            local_port="3000",
            program="Any",
        )
    ]

    def fake_get_netsh_firewall_rule(rule_name: str) -> firewall.FirewallRule | None:
        assert rule_name == firewall.PHYSICAL_BLOCK_RULE_NAME
        return block_rule

    def fake_get_inbound_allow_rows(
        ports: tuple[int, ...],
    ) -> list[firewall.PortMatch]:
        assert ports == firewall.LOCALAI_PORTS
        return inbound_rows

    monkeypatch.setattr(
        firewall,
        "get_netsh_firewall_rule",
        fake_get_netsh_firewall_rule,
    )
    monkeypatch.setattr(
        firewall,
        "get_inbound_allow_rows",
        fake_get_inbound_allow_rows,
    )

    code, lines = firewall.collect_firewall_report(
        now=datetime(2026, 6, 21, 14, 5, 0),
    )

    assert code == 0
    assert lines == [
        "==== localai firewall audit ====  2026-06-21 14:05:00",
        "[OK] Physical block           Block LocalAI ports on physical networks "
        "(localai) is enabled for ports 3000/8888/11434/8080/8880/8188",
        "[OK] Inbound ports            third-party allow rules are present but "
        "shadowed on WiFi/Ethernet by the LocalAI block: 3000",
        "",
        "Summary: 2 OK, 0 WARN, 0 FAIL",
    ]


def test_firewall_report_warns_when_owned_allow_rule_is_exposed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    inbound_rows = [
        firewall.PortMatch(
            port=3000,
            rule_name="Open WebUI LAN (localai)",
            profiles="Private",
            remote_ip="Any",
            local_port="3000",
            program="Any",
        )
    ]

    def fake_get_netsh_firewall_rule(rule_name: str) -> firewall.FirewallRule | None:
        assert rule_name == firewall.PHYSICAL_BLOCK_RULE_NAME
        return None

    def fake_get_inbound_allow_rows(
        ports: tuple[int, ...],
    ) -> list[firewall.PortMatch]:
        assert ports == firewall.LOCALAI_PORTS
        return inbound_rows

    monkeypatch.setattr(
        firewall,
        "get_netsh_firewall_rule",
        fake_get_netsh_firewall_rule,
    )
    monkeypatch.setattr(
        firewall,
        "get_inbound_allow_rows",
        fake_get_inbound_allow_rows,
    )

    code, lines = firewall.collect_firewall_report(
        now=datetime(2026, 6, 21, 14, 6, 0),
    )

    assert code == 1
    assert lines == [
        "==== localai firewall audit ====  2026-06-21 14:06:00",
        "[WARN] Physical block           missing; run -Apply to block LocalAI "
        "ports on WiFi/Ethernet",
        "[WARN] Port 3000                Open WebUI LAN (localai) [Private, "
        "remote=Any, localport=3000] - run -Apply to remove localai-owned "
        "rule(s)",
        "[WARN] Secure access            Tailscale Serve does not require "
        "inbound allow rules; run -Apply and review third-party rules above",
        "",
        "Summary: 0 OK, 3 WARN, 0 FAIL",
    ]


def test_firewall_apply_non_admin_reports_failure_then_audits(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    block_rule = firewall.FirewallRule(
        rule_name=firewall.PHYSICAL_BLOCK_RULE_NAME,
        enabled="Yes",
        action="Block",
        protocol="TCP",
        local_port="3000,8888,11434,8080,8880,8188",
    )

    monkeypatch.setattr(firewall, "is_admin", lambda: False)
    monkeypatch.setattr(
        firewall,
        "get_netsh_firewall_rule",
        lambda _rule_name: block_rule,
    )
    monkeypatch.setattr(firewall, "get_inbound_allow_rows", lambda _ports: [])

    code, lines = firewall.collect_firewall_report(
        apply=True,
        no_self_elevate=True,
        now=datetime(2026, 6, 21, 21, 6, 35),
    )

    assert code == 2
    assert lines == [
        "[FAIL] Apply                    Administrator rights are required for "
        "-Apply. Re-run this in an elevated PowerShell window.",
        "==== localai firewall audit ====  2026-06-21 21:06:35",
        "[OK] Physical block           Block LocalAI ports on physical networks "
        "(localai) is enabled for ports 3000/8888/11434/8080/8880/8188",
        "[OK] Inbound ports            no inbound allow rules for "
        "3000/8888/11434/8080/8880/8188",
        "",
        "Summary: 2 OK, 0 WARN, 1 FAIL",
    ]


def test_firewall_repair_removes_owned_rules_and_adds_block(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    deleted: list[str] = []
    added = False

    def fake_delete_firewall_rule(name: str) -> None:
        deleted.append(name)

    def fake_add_physical_block_rule() -> None:
        nonlocal added
        added = True

    monkeypatch.setattr(firewall, "is_admin", lambda: True)
    monkeypatch.setattr(
        firewall,
        "get_physical_adapter_aliases",
        lambda: ["Ethernet", "Wi-Fi"],
    )
    monkeypatch.setattr(firewall, "delete_firewall_rule", fake_delete_firewall_rule)
    monkeypatch.setattr(
        firewall,
        "add_physical_block_rule",
        fake_add_physical_block_rule,
    )

    aliases = firewall.repair_localai_firewall(no_self_elevate=True)

    assert aliases == ["Ethernet", "Wi-Fi"]
    assert added
    assert deleted == [
        "LocalAI-OpenWebUI-LAN",
        "LocalAI-OpenWebUI-Tailscale",
        "LocalAI-Block-Physical-Ports",
        "Open WebUI LAN (localai)",
        "Open WebUI Tailscale (localai)",
        "Block LocalAI ports on physical networks (localai)",
    ]


def test_firewall_physical_adapter_parser_filters_virtual_rows(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class Row:
        def __init__(self, alias: str) -> None:
            self.NetConnectionID = alias

    monkeypatch.setattr(
        firewall,
        "query_physical_adapter_rows",
        lambda: [
            Row("Wi-Fi"),
            Row("Tailscale"),
            Row("Ethernet"),
            Row("vEthernet (WSL)"),
        ],
    )

    assert firewall.get_physical_adapter_aliases() == ["Ethernet", "Wi-Fi"]


def test_firewall_wmi_access_denied_message_matches_legacy() -> None:
    assert (
        firewall.format_wmi_error(Exception("Access denied"))
        == "Access to a CIM resource was not available to the client."
    )


def test_firewall_add_block_rule_uses_native_netsh(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def fake_run_command(
        args: list[str],
        *,
        cwd: Path,
        timeout_sec: int,
    ) -> CommandResult:
        assert args == [
            "netsh",
            "advfirewall",
            "firewall",
            "add",
            "rule",
            "name=Block LocalAI ports on physical networks (localai)",
            "dir=in",
            "action=block",
            "enable=yes",
            "profile=any",
            "protocol=TCP",
            "localport=3000,8888,11434,8080,8880,8188",
            "interfacetype=lan,wireless",
        ]
        assert cwd == REPO_ROOT
        assert timeout_sec == 20
        return CommandResult(tuple(args), 0, "Ok.\n", "")

    monkeypatch.setattr(firewall, "run_command", fake_run_command)

    firewall.add_physical_block_rule()
