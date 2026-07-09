"""Firewall audit and repair ported from ai-firewall.ps1."""

from __future__ import annotations

import ctypes
import re
from dataclasses import dataclass
from datetime import datetime
from importlib import import_module
from typing import Any, cast

from localai.ops import run_command
from localai.paths import REPO_ROOT

PHYSICAL_BLOCK_RULE_NAME = "Block LocalAI ports on physical networks (localai)"
PHYSICAL_BLOCK_RULE_ID = "LocalAI-Block-Physical-Ports"
LOCALAI_RULE_IDS = (
    "LocalAI-OpenWebUI-LAN",
    "LocalAI-OpenWebUI-Tailscale",
    PHYSICAL_BLOCK_RULE_ID,
)
LOCALAI_PORTS = (3000, 8888, 11434, 8080, 8880, 8188)
LOCALAI_RULE_DISPLAY_NAMES = (
    "Open WebUI LAN (localai)",
    "Open WebUI Tailscale (localai)",
)


@dataclass
class Counters:
    ok: int = 0
    warn: int = 0
    fail: int = 0

    def add(self, status: str) -> None:
        if status == "OK":
            self.ok += 1
        elif status == "WARN":
            self.warn += 1
        elif status == "FAIL":
            self.fail += 1


@dataclass(frozen=True)
class FirewallRule:
    rule_name: str = ""
    enabled: str = ""
    direction: str = ""
    action: str = ""
    protocol: str = ""
    profiles: str = ""
    remote_ip: str = ""
    local_port: str = ""
    program: str = ""


@dataclass(frozen=True)
class PortMatch:
    port: int
    rule_name: str
    profiles: str
    remote_ip: str
    local_port: str
    program: str


def collect_firewall_report(
    *,
    apply: bool = False,
    no_self_elevate: bool = False,
    now: datetime | None = None,
) -> tuple[int, list[str]]:
    """Audit LocalAI firewall posture, optionally repairing localai-owned rules."""
    counters = Counters()
    lines: list[str] = []

    def add_line(status: str, name: str, detail: str) -> None:
        counters.add(status)
        lines.append(format_status_line(status, name, detail))

    if apply:
        try:
            aliases = repair_localai_firewall(no_self_elevate=no_self_elevate)
            if aliases:
                add_line(
                    "OK",
                    "Apply",
                    "removed legacy rules; blocked physical adapters: "
                    + ", ".join(aliases),
                )
            else:
                add_line("WARN", "Apply", "no firewall changes were applied")
        except RuntimeError as exc:
            add_line("FAIL", "Apply", str(exc))

    stamp = (now or datetime.now()).strftime("%Y-%m-%d %H:%M:%S")
    lines.append(f"==== localai firewall audit ====  {stamp}")

    block_rule = get_netsh_firewall_rule(PHYSICAL_BLOCK_RULE_NAME)
    block_protects_physical = False
    if (
        block_rule
        and block_rule.enabled == "Yes"
        and block_rule.action == "Block"
        and block_rule.protocol == "TCP"
    ):
        missing = [
            port
            for port in LOCALAI_PORTS
            if not port_spec_contains(block_rule.local_port, port)
        ]
        if not missing:
            block_protects_physical = True
            add_line(
                "OK",
                "Physical block",
                f"{PHYSICAL_BLOCK_RULE_NAME} is enabled for ports "
                f"{'/'.join(str(port) for port in LOCALAI_PORTS)}",
            )
        else:
            add_line(
                "WARN",
                "Physical block",
                "enabled but missing port(s) "
                f"{', '.join(str(port) for port in missing)}; run -Apply",
            )
    else:
        add_line(
            "WARN",
            "Physical block",
            "missing; run -Apply to block LocalAI ports on WiFi/Ethernet",
        )

    rows = get_inbound_allow_rows(LOCALAI_PORTS)
    if not rows:
        add_line(
            "OK",
            "Inbound ports",
            "no inbound allow rules for 3000/8888/11434/8080/8880/8188",
        )
    elif block_protects_physical:
        ports = sorted({row.port for row in rows})
        add_line(
            "OK",
            "Inbound ports",
            "third-party allow rules are present but shadowed on WiFi/Ethernet "
            f"by the LocalAI block: {'/'.join(str(port) for port in ports)}",
        )
    else:
        for port in sorted({row.port for row in rows}):
            matches = [row for row in rows if row.port == port]
            rules = sorted(
                {
                    f"{row.rule_name} [{row.profiles}, remote={row.remote_ip}, "
                    f"localport={row.local_port}]"
                    for row in matches
                }
            )
            owned = [
                row
                for row in matches
                if row.rule_name in LOCALAI_RULE_DISPLAY_NAMES
            ]
            suffix = (
                " - run -Apply to remove localai-owned rule(s)" if owned else ""
            )
            add_line("WARN", f"Port {port}", "; ".join(rules) + suffix)
        add_line(
            "WARN",
            "Secure access",
            "Tailscale Serve does not require inbound allow rules; run -Apply "
            "and review third-party rules above",
        )

    lines.append("")
    lines.append(
        f"Summary: {counters.ok} OK, {counters.warn} WARN, {counters.fail} FAIL"
    )
    if counters.fail > 0:
        return 2, lines
    if counters.warn > 0:
        return 1, lines
    return 0, lines


def format_status_line(status: str, name: str, detail: str) -> str:
    return f"[{status}] {name:<24} {detail}"


def repair_localai_firewall(*, no_self_elevate: bool) -> list[str]:
    if not is_admin():
        if not no_self_elevate:
            # Keep the Python port non-interactive: no PowerShell self-elevation
            # shim, and no hidden UAC prompt from a CLI command.
            msg = (
                "Administrator rights are required for -Apply. Re-run this in "
                "an elevated terminal."
            )
        else:
            msg = (
                "Administrator rights are required for -Apply. Re-run this in "
                "an elevated PowerShell window."
            )
        raise RuntimeError(msg)

    aliases = get_physical_adapter_aliases()
    if not aliases:
        msg = "No physical network adapters found for the LocalAI block rule."
        raise RuntimeError(msg)

    names = (*LOCALAI_RULE_IDS, *LOCALAI_RULE_DISPLAY_NAMES, PHYSICAL_BLOCK_RULE_NAME)
    for name in names:
        delete_firewall_rule(name)

    add_physical_block_rule()
    return aliases


def is_admin() -> bool:
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except (AttributeError, OSError):
        return False


def get_physical_adapter_aliases() -> list[str]:
    aliases = []
    for row in query_physical_adapter_rows():
        alias = physical_adapter_alias_from_wmi_row(row)
        if alias is not None:
            aliases.append(alias)
    return sorted(set(aliases))


def query_physical_adapter_rows() -> list[Any]:
    try:
        win32com_client = cast(Any, import_module("win32com.client"))
    except ModuleNotFoundError as exc:
        msg = "pywin32 is not installed"
        raise RuntimeError(msg) from exc

    try:
        service = win32com_client.GetObject("winmgmts:root\\cimv2")
        rows = service.ExecQuery(
            "SELECT NetConnectionID FROM Win32_NetworkAdapter "
            "WHERE PhysicalAdapter=True AND NetEnabled=True"
        )
    except Exception as exc:
        raise RuntimeError(format_wmi_error(exc)) from exc

    return list(rows)


def physical_adapter_alias_from_wmi_row(row: Any) -> str | None:
    try:
        alias = str(row.NetConnectionID or "").strip()
    except AttributeError:
        return None
    if not alias:
        return None
    if re.search(
        r"Tailscale|Loopback|vEthernet|Docker|WSL",
        alias,
        flags=re.IGNORECASE,
    ):
        return None
    return alias


def format_wmi_error(exc: BaseException) -> str:
    text = str(exc).strip()
    if "Access denied" in text:
        return "Access to a CIM resource was not available to the client."
    return text if text else exc.__class__.__name__


def delete_firewall_rule(name: str) -> None:
    run_command(
        [
            "netsh",
            "advfirewall",
            "firewall",
            "delete",
            "rule",
            f"name={name}",
        ],
        cwd=REPO_ROOT,
        timeout_sec=20,
    )


def add_physical_block_rule() -> None:
    result = run_command(
        [
            "netsh",
            "advfirewall",
            "firewall",
            "add",
            "rule",
            f"name={PHYSICAL_BLOCK_RULE_NAME}",
            "dir=in",
            "action=block",
            "enable=yes",
            "profile=any",
            "protocol=TCP",
            f"localport={','.join(str(port) for port in LOCALAI_PORTS)}",
            "interfacetype=lan,wireless",
        ],
        cwd=REPO_ROOT,
        timeout_sec=20,
    )
    if result.code != 0:
        raise RuntimeError(result.text.strip())


def get_netsh_firewall_rule(rule_name: str) -> FirewallRule | None:
    result = run_command(
        [
            "netsh",
            "advfirewall",
            "firewall",
            "show",
            "rule",
            f"name={rule_name}",
            "verbose",
        ],
        cwd=REPO_ROOT,
        timeout_sec=20,
    )
    text = result.text
    if result.code != 0 or "No rules match" in text:
        return None
    rules = parse_netsh_rules(text)
    return rules[0] if rules else None


def get_inbound_allow_rows(ports: tuple[int, ...]) -> list[PortMatch]:
    result = run_command(
        [
            "netsh",
            "advfirewall",
            "firewall",
            "show",
            "rule",
            "name=all",
            "dir=in",
        ],
        cwd=REPO_ROOT,
        timeout_sec=20,
    )
    if result.code != 0:
        raise RuntimeError(result.text)

    rows: list[PortMatch] = []
    for rule in parse_netsh_rules(result.text):
        if (
            rule.enabled == "Yes"
            and rule.direction == "In"
            and rule.action == "Allow"
            and rule.protocol == "TCP"
            and rule.local_port
        ):
            rows.extend(matching_ports(rule, ports))
    return rows


def parse_netsh_rules(text: str) -> list[FirewallRule]:
    current: dict[str, str] = {}
    rules: list[FirewallRule] = []
    for raw_line in text.splitlines():
        line = raw_line.rstrip()
        match = re.match(r"^Rule Name:\s*(.+)$", line)
        if match:
            if current:
                rules.append(rule_from_fields(current))
            current = {"Rule Name": match.group(1).strip()}
            continue
        if not current:
            continue
        field = re.match(r"^([A-Za-z ]+):\s*(.*)$", line)
        if field:
            current[field.group(1).strip()] = field.group(2).strip()
    if current:
        rules.append(rule_from_fields(current))
    return rules


def rule_from_fields(fields: dict[str, str]) -> FirewallRule:
    return FirewallRule(
        rule_name=fields.get("Rule Name", ""),
        enabled=fields.get("Enabled", ""),
        direction=fields.get("Direction", ""),
        action=fields.get("Action", ""),
        protocol=fields.get("Protocol", ""),
        profiles=fields.get("Profiles", ""),
        remote_ip=fields.get("RemoteIP", ""),
        local_port=fields.get("LocalPort", ""),
        program=fields.get("Program", ""),
    )


def matching_ports(rule: FirewallRule, ports: tuple[int, ...]) -> list[PortMatch]:
    rows: list[PortMatch] = []
    for part in split_port_spec(rule.local_port):
        range_match = re.match(r"^(\d+)-(\d+)$", part)
        if range_match:
            first = int(range_match.group(1))
            last = int(range_match.group(2))
            for port in ports:
                if first <= port <= last:
                    rows.append(port_match(rule, port))
            continue
        if part.isdigit():
            port = int(part)
            if port in ports:
                rows.append(port_match(rule, port))
    return rows


def port_match(rule: FirewallRule, port: int) -> PortMatch:
    return PortMatch(
        port=port,
        rule_name=rule.rule_name,
        profiles=rule.profiles,
        remote_ip=rule.remote_ip,
        local_port=rule.local_port,
        program=rule.program,
    )


def port_spec_contains(local_port_spec: str, port: int) -> bool:
    for part in split_port_spec(local_port_spec):
        if part == "Any":
            return True
        range_match = re.match(r"^(\d+)-(\d+)$", part)
        if (
            range_match
            and int(range_match.group(1)) <= port <= int(range_match.group(2))
        ):
            return True
        if part.isdigit() and int(part) == port:
            return True
    return False


def split_port_spec(local_port_spec: str) -> list[str]:
    return [part.strip() for part in str(local_port_spec).split(",") if part.strip()]
