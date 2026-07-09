"""Secure Tailscale access checks ported from ai-anywhere.ps1."""

from __future__ import annotations

import json
import os
import re
import shutil
import webbrowser
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any
from urllib.error import URLError
from urllib.request import urlopen

from localai.ops import run_command
from localai.paths import repo_path

DOWNLOAD_URL = "https://tailscale.com/download/windows"


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
class TailscaleSelf:
    connected: bool
    detail: str
    url: str
    dns_name: str
    ips: tuple[str, ...]


@dataclass(frozen=True)
class ServeStatus:
    code: int
    text: str
    proxy_targets: tuple[str, ...] = ()

    def proxies_to_port(self, port: int) -> bool:
        """True if any Serve handler proxies to the given local port."""
        needles = (f"127.0.0.1:{port}", f"localhost:{port}")
        return any(
            needle in target for needle in needles for target in self.proxy_targets
        )


def collect_anywhere_report(
    *,
    apply: bool = False,
    install_tailscale: bool = False,
    open_url: bool = False,
    port: int = 3000,
    now: datetime | None = None,
) -> tuple[int, list[str]]:
    """Collect secure-anywhere access status and optionally repair Tailscale Serve.

    Read-only audit mode reports problems as WARN and exits 0. With --apply,
    failing to reach the requested Serve state is a FAIL with a differentiated
    exit code so a caller knows why: 10 Tailscale not installed, 11 not signed
    in, 12 local Open WebUI backend unhealthy, 13 Serve apply failed / inactive.
    """
    counters = Counters()
    stamp = (now or datetime.now()).strftime("%Y-%m-%d %H:%M:%S")
    lines = [f"==== localai secure anywhere access ====  {stamp}"]
    apply_failure = 0

    def add_line(status: str, name: str, detail: str) -> None:
        counters.add(status)
        lines.append(format_status_line(status, name, detail))

    def summary() -> tuple[int, list[str]]:
        lines.append("")
        lines.append(
            f"Summary: {counters.ok} OK, {counters.warn} WARN, {counters.fail} FAIL"
        )
        if apply and apply_failure:
            return apply_failure, lines
        return (1 if counters.fail > 0 else 0), lines

    if install_tailscale:
        install_tailscale_with_winget(add_line)

    compose_text = read_text_if_exists(repo_path("docker-compose.yml"))
    if re.search(r"127\.0\.0\.1:3000:8080", compose_text):
        add_line("OK", "Open WebUI bind", "localhost-only Docker publish")
    elif re.search(r"0\.0\.0\.0:3000:8080", compose_text):
        add_line(
            "WARN",
            "Open WebUI bind",
            "LAN-wide Docker publish; change to 127.0.0.1 for strict secure access",
        )
    else:
        add_line("WARN", "Open WebUI bind", "could not confirm Docker port binding")

    owui = http_code(f"http://127.0.0.1:{port}/health", timeout_sec=3)
    if owui == 200:
        add_line("OK", "Open WebUI local", f"http://127.0.0.1:{port} health HTTP 200")
    else:
        add_line(
            "FAIL" if apply else "WARN",
            "Open WebUI local",
            f"health HTTP {owui}; start Local AI before testing remote devices",
        )
        if apply:
            apply_failure = apply_failure or 12

    tailscale = resolve_tailscale()
    if tailscale is None:
        add_line(
            "FAIL" if apply else "WARN",
            "Tailscale",
            f"not installed; run with -InstallTailscale or install from {DOWNLOAD_URL}",
        )
        if apply:
            apply_failure = apply_failure or 10
        return summary()

    add_line("OK", "Tailscale", str(tailscale))
    self = get_tailscale_self(tailscale, port)
    if self.connected:
        ip_text = ", ".join(self.ips) if self.ips else "no tailnet IP reported"
        add_line("OK", "Tailnet login", f"{self.detail}; {ip_text}")
    else:
        detail = self.detail if self.detail else "open Tailscale and sign in"
        add_line("FAIL" if apply else "WARN", "Tailnet login", detail)
        if apply:
            apply_failure = apply_failure or 11

    if apply:
        if not self.connected:
            add_line(
                "FAIL",
                "Tailscale Serve",
                "sign in to Tailscale first, then rerun: localai anywhere --apply",
            )
            apply_failure = apply_failure or 11
        else:
            serve = run_command(
                [str(tailscale), "serve", "--bg", str(port)], timeout_sec=30
            )
            if serve.code == 0:
                add_line(
                    "OK",
                    "Tailscale Serve",
                    f"proxying tailnet HTTPS to http://127.0.0.1:{port}",
                )
            else:
                if serve.text.strip():
                    lines.append(normalize_whitespace(serve.text))
                add_line(
                    "FAIL",
                    "Tailscale Serve",
                    "serve command failed or requires consent; see output above",
                )
                add_line(
                    "WARN",
                    "Serve consent",
                    "follow any Tailscale consent URL above, then rerun --apply",
                )
                apply_failure = apply_failure or 13

    serve_status = get_serve_status(tailscale)
    if serve_status.code == 0 and serve_status.proxies_to_port(port):
        url = self.url if self.url else "the HTTPS URL shown by tailscale serve status"
        add_line("OK", "Anywhere URL", url)
    else:
        hint = (
            "Serve is not active yet; see message above"
            if apply
            else "run: localai anywhere --apply"
        )
        add_line("FAIL" if apply else "WARN", "Anywhere URL", hint)
        if apply:
            apply_failure = apply_failure or 13

    funnel = run_command([str(tailscale), "funnel", "status"], timeout_sec=15)
    funnel_text = normalize_whitespace(funnel.text)
    if (
        funnel.code == 0
        and re.search(r"https?://", funnel_text)
        and not re.search(r"not enabled|tailnet only", funnel_text)
    ):
        add_line(
            "WARN",
            "Tailscale Funnel",
            "public internet sharing appears enabled; use Serve, not Funnel, "
            "for localai",
        )
    else:
        add_line(
            "OK",
            "Tailscale Funnel",
            "not publishing localai to the public internet",
        )

    if open_url and self.url:
        webbrowser.open(self.url)

    return summary()


def format_status_line(status: str, name: str, detail: str) -> str:
    return f"[{status}] {name:<22} {detail}"


def read_text_if_exists(path: Path) -> str:
    if path.exists():
        return path.read_text(encoding="utf-8")
    return ""


def http_code(url: str, *, timeout_sec: float) -> int:
    try:
        with urlopen(url, timeout=timeout_sec) as response:
            return int(response.status)
    except (OSError, TimeoutError, URLError):
        return 0


def resolve_tailscale() -> Path | None:
    path = shutil.which("tailscale.exe") or shutil.which("tailscale")
    if path:
        return Path(path)

    candidates = [
        Path(os.environ["PROGRAMFILES"]) / "Tailscale" / "tailscale.exe"
        if os.environ.get("PROGRAMFILES")
        else None,
        Path(os.environ["PROGRAMFILES(X86)"]) / "Tailscale" / "tailscale.exe"
        if os.environ.get("PROGRAMFILES(X86)")
        else None,
        Path(os.environ["LOCALAPPDATA"]) / "Tailscale" / "tailscale.exe"
        if os.environ.get("LOCALAPPDATA")
        else None,
    ]
    for candidate in candidates:
        if candidate and candidate.exists():
            return candidate
    return None


def install_tailscale_with_winget(
    add_line: Callable[[str, str, str], None],
) -> None:
    winget = shutil.which("winget.exe") or shutil.which("winget")
    if winget is None:
        add_line(
            "FAIL",
            "Tailscale install",
            f"winget not found; install from {DOWNLOAD_URL}",
        )
        return

    add_line("OK", "Tailscale install", "starting winget install")
    result = run_command(
        [
            winget,
            "install",
            "--id",
            "Tailscale.Tailscale",
            "-e",
            "--source",
            "winget",
            "--accept-package-agreements",
            "--accept-source-agreements",
        ],
        timeout_sec=900,
    )
    if result.code == 0:
        add_line("OK", "Tailscale install", "installed or already present")
    else:
        add_line("FAIL", "Tailscale install", normalize_whitespace(result.text))


def get_tailscale_self(tailscale: Path, port: int) -> TailscaleSelf:
    status = run_command([str(tailscale), "status", "--json"], timeout_sec=20)
    if status.code != 0 or not status.text.strip():
        return TailscaleSelf(
            False,
            normalize_whitespace(status.text),
            "",
            "",
            (),
        )

    try:
        payload = json.loads(status.text)
        self_node = payload.get("Self") or {}
        ips = tuple(str(ip) for ip in self_node.get("TailscaleIPs", []) if ip)
        dns = str(self_node.get("DNSName") or "").rstrip(".")
        online = bool(self_node.get("Online"))
        backend = str(payload.get("BackendState") or "")
        connected = online or backend == "Running"
        # Open WebUI binds 127.0.0.1 only; a direct http://<tailscale-ip>:<port>
        # URL cannot reach it. The only valid remote URL is Tailscale Serve's
        # HTTPS MagicDNS name, so emit nothing when DNS is unavailable.
        url = f"https://{dns}" if dns else ""
        detail = (
            f"online as {self_node.get('HostName')}"
            if connected
            else not_connected_detail(backend)
        )
        return TailscaleSelf(connected, detail, url, dns, ips)
    except (TypeError, json.JSONDecodeError) as exc:
        return TailscaleSelf(False, str(exc), "", "", ())


def not_connected_detail(backend: str) -> str:
    match backend:
        case "NoState":
            return (
                "Tailscale is not signed in - open Tailscale and sign in, then "
                "rerun this check"
            )
        case "NeedsLogin":
            return (
                "Tailscale needs you to sign in - open Tailscale and sign in, then "
                "rerun this check"
            )
        case "Starting":
            return (
                "Tailscale is still starting up - wait a few seconds and rerun "
                "this check"
            )
        case "Stopped":
            return "Tailscale is stopped - open Tailscale, then rerun this check"
        case _:
            return f"Tailscale backend state: {backend}"


def get_serve_status(tailscale: Path) -> ServeStatus:
    status = run_command([str(tailscale), "serve", "status", "--json"], timeout_sec=20)
    text = normalize_whitespace(status.text)
    if status.code != 0 or not status.stdout.strip():
        return ServeStatus(status.code, text, ())

    try:
        payload = json.loads(status.stdout)
    except json.JSONDecodeError:
        return ServeStatus(status.code, text, ())

    return ServeStatus(status.code, text, tuple(extract_proxy_targets(payload)))


def extract_proxy_targets(payload: dict[str, Any]) -> list[str]:
    """Pull every handler proxy target out of a 'serve status --json' payload."""
    targets: list[str] = []
    web = payload.get("Web") or {}
    for host_entry in web.values():
        handlers = (host_entry or {}).get("Handlers") or {}
        for handler in handlers.values():
            proxy = (handler or {}).get("Proxy")
            if proxy:
                targets.append(str(proxy))
    return targets


def normalize_whitespace(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()
