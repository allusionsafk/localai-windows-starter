from __future__ import annotations

import re
import sys
import tomllib
from pathlib import Path

import pytest

from localai import __version__
from localai.anywhere import (
    TailscaleSelf,
    get_tailscale_self,
    normalize_whitespace,
)
from localai.anywhere import (
    format_status_line as format_anywhere_status_line,
)
from localai.firewall import (
    FirewallRule,
    matching_ports,
    parse_netsh_rules,
    port_spec_contains,
)
from localai.firewall import (
    format_status_line as format_firewall_status_line,
)
from localai.game_mode import (
    ProcessInfo,
    format_wmi_error,
    is_comfyui_process,
    parse_ollama_ps,
    process_from_wmi_row,
)
from localai.ops import CommandResult, run_command
from localai.paths import repo_path
from localai.perf import (
    format_status_line as format_perf_status_line,
)
from localai.perf import (
    read_default_model,
    read_default_model_params,
    read_task_model,
)
from localai.power import (
    format_number,
    format_status_line,
    parse_schtasks_status,
)
from localai.public_audit import (
    Finding,
    grouped_counts,
    scan_text,
)
from localai.public_audit import (
    format_status_line as format_public_audit_status_line,
)
from localai.terminal_check import (
    collapse_whitespace,
    model_known,
    normalize_aider_version,
    path_list_contains,
)
from localai.terminal_check import (
    format_status_line as format_terminal_status_line,
)


def test_project_metadata_matches_package_version() -> None:
    metadata = tomllib.loads(repo_path("pyproject.toml").read_text(encoding="utf-8"))

    assert metadata["project"]["name"] == "localai"
    assert metadata["project"]["version"] == __version__
    assert metadata["project"]["requires-python"] == ">=3.12"
    assert metadata["project"]["scripts"]["localai"] == "localai.cli:app"


def test_run_command_captures_stdout() -> None:
    command = "import sys; print('ok'); print('warn', file=sys.stderr)"
    result = run_command(
        [sys.executable, "-c", command]
    )

    assert result == CommandResult(
        args=(
            sys.executable,
            "-c",
            command,
        ),
        code=0,
        stdout="ok\n",
        stderr="warn\n",
    )
    assert result.text == "ok\nwarn\n"


def test_run_command_rejects_empty_args() -> None:
    with pytest.raises(ValueError, match="args must contain an executable"):
        run_command([])


def test_power_status_line_matches_legacy_width() -> None:
    assert (
        format_status_line("OK", "Power source", "plugged in")
        == "[OK] Power source           plugged in"
    )


def test_parse_schtasks_status() -> None:
    assert parse_schtasks_status("TaskName: \\AI-Warm\r\nStatus: Ready\r\n") == "Ready"
    assert parse_schtasks_status("TaskName: \\AI-Warm\r\n") is None


def test_format_number_matches_powershell_style() -> None:
    assert format_number(12.0) == "12"
    assert format_number(0.9) == "0.9"


def test_anywhere_status_line_matches_legacy_width() -> None:
    assert (
        format_anywhere_status_line("OK", "Open WebUI bind", "localhost-only")
        == "[OK] Open WebUI bind        localhost-only"
    )


def test_normalize_whitespace() -> None:
    assert normalize_whitespace("one\r\n  two\tthree") == "one two three"


def test_get_tailscale_self_from_status_json(monkeypatch: pytest.MonkeyPatch) -> None:
    payload = (
        '{"BackendState":"Running","Self":{"Online":false,"HostName":"host",'
        '"DNSName":"host.example.test.","TailscaleIPs":["10.0.0.1"]}}'
    )

    def fake_run_command(
        args: list[str],
        *,
        timeout_sec: int,
    ) -> CommandResult:
        assert args[0].endswith("tailscale.exe")
        assert args[1:] == ["status", "--json"]
        assert timeout_sec == 20
        return CommandResult(tuple(args), 0, payload, "")

    monkeypatch.setattr("localai.anywhere.run_command", fake_run_command)

    assert get_tailscale_self(repo_path("tailscale.exe"), 3000) == TailscaleSelf(
        connected=True,
        detail="online as host",
        url="https://host.example.test",
        dns_name="host.example.test",
        ips=("10.0.0.1",),
    )


def test_public_audit_status_line_matches_legacy_width() -> None:
    assert (
        format_public_audit_status_line("WARN", "Laptop hardware", "1 hit(s)")
        == "[WARN] Laptop hardware        1 hit(s)"
    )


def test_public_audit_group_counts_sort_by_kind() -> None:
    findings = [
        Finding("Tailnet URL", "a.txt", 1, "one"),
        Finding("Laptop hardware", "b.txt", 1, "two"),
        Finding("Tailnet URL", "c.txt", 1, "three"),
    ]

    assert grouped_counts(findings) == [("Laptop hardware", 1), ("Tailnet URL", 2)]


def test_public_audit_scan_text() -> None:
    findings = scan_text(
        "README.md",
        "private GPU-X\nsafe\nhttps://node.example.test\n",
        [
            ("Laptop hardware", re.compile(r"GPU-X")),
            ("Tailnet URL", re.compile(r"\bnode\.example\.test\b")),
        ],
    )

    assert findings == [
        Finding("Laptop hardware", "README.md", 1, "private GPU-X"),
        Finding("Tailnet URL", "README.md", 3, "https://node.example.test"),
    ]


def test_perf_status_line_matches_legacy_width() -> None:
    assert (
        format_perf_status_line("OK", "Ollama binary", "path")
        == "[OK] Ollama binary            path"
    )


def test_perf_compose_parsers() -> None:
    compose = """
    - DEFAULT_MODELS=qwen2.5-grounded
    - TASK_MODEL=
    - DEFAULT_MODEL_PARAMS={"stream_response":true,"keep_alive":"30m"}
    """

    assert read_default_model(compose) == "qwen2.5-grounded"
    assert read_task_model(compose) == ""
    assert read_default_model_params(compose) == {
        "stream_response": True,
        "keep_alive": "30m",
    }


def test_terminal_status_line_matches_legacy_width() -> None:
    assert (
        format_terminal_status_line("OK", "Start-TerminalAI", "syntax OK")
        == "[OK] Start-TerminalAI         syntax OK"
    )


def test_terminal_path_list_contains() -> None:
    directory = Path("C:/Users/example/.local/bin")
    path_value = f"C:\\Other;{directory}"

    assert path_list_contains(directory, path_value)


def test_terminal_model_known() -> None:
    assert model_known(["qwen2.5-grounded:latest"], "qwen2.5-grounded")
    assert not model_known(["other:latest"], "qwen2.5-grounded")


def test_collapse_whitespace() -> None:
    assert collapse_whitespace("aider\r\n 0.86.2") == "aider 0.86.2"


def test_normalize_aider_version() -> None:
    assert normalize_aider_version("aider.EXE 0.86.2") == "aider 0.86.2"


def test_firewall_status_line_matches_legacy_width() -> None:
    assert (
        format_firewall_status_line("OK", "Physical block", "enabled")
        == "[OK] Physical block           enabled"
    )


def test_firewall_parse_netsh_rule() -> None:
    text = """
Rule Name:                            Block LocalAI ports on physical networks (localai)
----------------------------------------------------------------------
Enabled:                              Yes
Direction:                            In
Profiles:                             Domain,Private,Public
RemoteIP:                             Any
Protocol:                             TCP
LocalPort:                            3000,8888,11434
Action:                               Block
Ok.
"""

    assert parse_netsh_rules(text) == [
        FirewallRule(
            rule_name="Block LocalAI ports on physical networks (localai)",
            enabled="Yes",
            direction="In",
            action="Block",
            protocol="TCP",
            profiles="Domain,Private,Public",
            remote_ip="Any",
            local_port="3000,8888,11434",
        )
    ]


def test_firewall_port_spec_helpers() -> None:
    rule = FirewallRule(
        rule_name="Example",
        profiles="Private",
        remote_ip="Any",
        local_port="8080-8082,8888",
    )

    assert port_spec_contains("3000,8080-8082", 8081)
    assert not port_spec_contains("3000,8080-8082", 8888)
    assert [row.port for row in matching_ports(rule, (3000, 8080, 8081, 8888))] == [
        8080,
        8081,
        8888,
    ]


def test_game_mode_parse_ollama_ps() -> None:
    text = (
        "NAME ID SIZE PROCESSOR UNTIL\n"
        "qwen2.5-grounded:latest abc 9 GB 100% GPU 4m\n"
    )

    assert parse_ollama_ps(text) == ["qwen2.5-grounded:latest"]


def test_game_mode_process_from_wmi_row() -> None:
    class Row:
        ProcessId = "1234"
        Name = "python.exe"
        CommandLine = r"python C:\ComfyUI\main.py"

    assert process_from_wmi_row(Row()) == ProcessInfo(
        pid=1234,
        name="python.exe",
        command_line=r"python C:\ComfyUI\main.py",
    )


def test_game_mode_wmi_access_denied_message_matches_legacy() -> None:
    assert (
        format_wmi_error(Exception("Access denied"))
        == "Access to a CIM resource was not available to the client."
    )


def test_game_mode_comfyui_match() -> None:
    process = ProcessInfo(
        pid=1234,
        name="python.exe",
        command_line=r"python C:\ComfyUI\main.py",
    )

    assert is_comfyui_process(process)
