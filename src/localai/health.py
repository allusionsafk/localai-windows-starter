"""Read-only stack health check ported from ai-health.ps1."""

from __future__ import annotations

import json
import os
import re
import socket
import tempfile
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from urllib.error import URLError
from urllib.request import Request, urlopen

from localai import compose, firewall
from localai.anywhere import normalize_whitespace, resolve_tailscale
from localai.ops import run_command
from localai.paths import REPO_ROOT, repo_path
from localai.perf import read_default_model, read_default_model_params, read_task_model
from localai.power import format_number

AddLine = Callable[[str, str, str], None]
LOCALAI_PORTS = (3000, 8888, 11434, 8080, 8880, 8188)
EXPECTED_ALIASES = (
    "deep-thinking-qwen3.6",
    "full-thinking-qwen3.6",
    "voice-qwen3-grounded",
    "fast-voice-qwen2.5-14b",
    "image-prompt-qwen3-grounded",
    "image-fast-prompt-qwen2.5-14b",
    "web-search-qwen3-grounded",
    "web-search-deep-qwen3.6",
    "terminal-code-qwen2.5-coder-14b",
    "terminal-agent-qwen3-coder-30b",
    "vision-qwen2.5vl-7b",
)
ALIAS_SOURCES = {
    "deep-thinking-qwen3.6": "qwen3.6-thinklight-grounded",
    "full-thinking-qwen3.6": "qwen3.6-35b-a3b-grounded",
    "voice-qwen3-grounded": "qwen3-grounded",
    "fast-voice-qwen2.5-14b": "qwen2.5:14b",
    "image-prompt-qwen3-grounded": "qwen3-grounded",
    "image-fast-prompt-qwen2.5-14b": "qwen2.5:14b",
    "web-search-qwen3-grounded": "qwen3-grounded",
    "web-search-deep-qwen3.6": "qwen3.6-thinklight-grounded",
    "terminal-code-qwen2.5-coder-14b": "qwen2.5-coder:14b",
    "terminal-agent-qwen3-coder-30b": "qwen3-coder:30b",
    "vision-qwen2.5vl-7b": "qwen2.5vl:7b",
}
KNOWN_DEFAULT_ALIASES = {
    "voice-qwen3-grounded",
    "deep-thinking-qwen3.6",
    "full-thinking-qwen3.6",
    "web-search-deep-qwen3.6",
}


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


def collect_health_report(
    *,
    now: datetime | None = None,
) -> tuple[int, list[str]]:
    """Collect the same read-only health posture as ai-health.ps1."""
    counters = Counters()
    stamp = (now or datetime.now()).strftime("%Y-%m-%d %H:%M:%S")
    lines = [f"==== localai health ====  {stamp}"]
    compose_text = read_compose_text()
    default_model = read_default_model(compose_text) or "unknown"
    task_model = read_task_model(compose_text)

    def add_line(status: str, name: str, detail: str) -> None:
        counters.add(status)
        lines.append(format_status_line(status, name, detail))

    check_docker_containers(add_line)
    check_open_webui(add_line, compose_text)
    check_tailscale(add_line)
    check_model_config(add_line, compose_text, default_model, task_model)
    check_open_webui_thinking(add_line)
    check_terminal_launchers(add_line)
    check_terminal_commands(add_line)
    check_node_smoke(
        add_line,
        "Cherry MCP direct",
        "test-filesystem-mcp.mjs",
        "filesystem MCP direct stdio test: OK",
        "filesystem stdio server lists Documents",
    )
    check_node_smoke(
        add_line,
        "MCP bundle",
        "test-mcp-bundle.mjs",
        "MCP bundle test: OK",
        "filesystem, memory, thinking, browser, localai tools",
        timeout_sec=45,
    )
    check_nanobrowser(add_line, default_model)
    check_cherry_agent(add_line)
    check_ollama(add_line, default_model)
    check_open_webui_reaches_ollama(add_line)
    check_tiny_inference(add_line, default_model)
    check_searxng(add_line)
    check_kokoro(add_line)
    check_image_studio(add_line)
    check_gpu_memory(add_line)
    check_firewall(add_line)
    check_git_secret_guard(add_line)

    lines.append("")
    lines.append(
        f"Summary: {counters.ok} OK, {counters.warn} WARN, {counters.fail} FAIL"
    )
    return (1 if counters.fail > 0 else 0), lines


def format_status_line(status: str, name: str, detail: str) -> str:
    return f"[{status}] {name:<24} {detail}"


def read_compose_text() -> str:
    compose = repo_path("docker-compose.yml")
    return compose.read_text(encoding="utf-8") if compose.exists() else ""


def ollama_path() -> Path:
    local_app_data = os.environ.get("LOCALAPPDATA", "")
    return Path(local_app_data) / "Programs" / "Ollama" / "ollama.exe"


def check_docker_containers(add_line: AddLine) -> None:
    # Probe the daemon directly; if it is down, one honest FAIL (we cannot judge
    # any service). Otherwise resolve each service by its compose name rather than
    # a guessed localai-<svc>-1 container name (audit #6).
    probe = run_command(
        ["docker", "info", "--format", "{{.ServerVersion}}"],
        cwd=REPO_ROOT,
        timeout_sec=20,
    )
    if probe.code != 0:
        add_line("FAIL", "Docker", "daemon not reachable")
        return
    for service in ("open-webui", "searxng", "kokoro"):
        status = compose.compose_service_status(service)
        if status is None:
            add_line("FAIL", service, "not running")
        elif status.state == "running" and status.health in (None, "healthy"):
            add_line("OK", status.name, status.status_text or status.state)
        else:
            detail = status.status_text or status.state or "not running"
            add_line("FAIL", status.name, detail)


def check_open_webui(add_line: AddLine, compose_text: str) -> None:
    code = http_code("http://127.0.0.1:3000/health", timeout_sec=3)
    if code == 200:
        add_line("OK", "Open WebUI local", "health HTTP 200")
    else:
        add_line("FAIL", "Open WebUI local", f"health HTTP {code}")

    if re.search(r"127\.0\.0\.1:3000:8080", compose_text):
        add_line("OK", "Open WebUI bind", "localhost-only; devices use Tailscale Serve")
    elif re.search(r"0\.0\.0\.0:3000:8080", compose_text):
        add_line(
            "WARN",
            "Open WebUI bind",
            "LAN-wide publish; switch to 127.0.0.1 for secure anywhere access",
        )
    else:
        add_line("WARN", "Open WebUI bind", "could not confirm Docker port binding")


def check_tailscale(add_line: AddLine) -> None:
    tailscale = resolve_tailscale()
    if tailscale is None:
        add_line(
            "WARN",
            "Anywhere access",
            "Tailscale not installed; run ai-anywhere.ps1 -InstallTailscale",
        )
        return

    tailnet_url = ""
    status = run_command(
        [str(tailscale), "status", "--json"], cwd=REPO_ROOT, timeout_sec=15
    )
    if status.code != 0 or not status.text.strip():
        add_line("WARN", "Tailnet login", "Tailscale is installed but not signed in")
    else:
        try:
            payload = json.loads(status.text)
            self_row = payload.get("Self") if isinstance(payload, dict) else {}
            self_row = self_row if isinstance(self_row, dict) else {}
            dns = str(self_row.get("DNSName") or "").rstrip(".")
            ips = [str(ip) for ip in self_row.get("TailscaleIPs") or [] if ip]
            # Loopback-only backend: no valid direct tailscale-IP URL exists;
            # only Tailscale Serve's HTTPS MagicDNS name works remotely.
            tailnet_url = f"https://{dns}" if dns else ""
            if (
                bool(self_row.get("Online"))
                or str(payload.get("BackendState")) == "Running"
            ):
                add_line("OK", "Tailnet login", f"online; {', '.join(ips)}")
            else:
                add_line(
                    "WARN", "Tailnet login", f"backend={payload.get('BackendState')}"
                )
        except (TypeError, json.JSONDecodeError) as exc:
            add_line("WARN", "Tailnet login", str(exc))

    serve = run_command(
        [str(tailscale), "serve", "status"], cwd=REPO_ROOT, timeout_sec=15
    )
    serve_text = normalize_whitespace(serve.text)
    if serve.code == 0 and re.search(
        r"127\.0\.0\.1:3000|localhost:3000|:3000", serve_text
    ):
        add_line(
            "OK",
            "Anywhere URL",
            tailnet_url or "Tailscale Serve routes to localhost:3000",
        )
    else:
        add_line(
            "WARN",
            "Anywhere URL",
            "not active; run ai-anywhere.ps1 -Apply after Tailscale sign-in",
        )


def check_model_config(
    add_line: AddLine,
    compose_text: str,
    default_model: str,
    task_model: str | None,
) -> None:
    base = default_model.removesuffix(":latest")
    if base.endswith("-grounded") or base in KNOWN_DEFAULT_ALIASES:
        add_line("OK", "Default model", default_model)
    else:
        add_line("WARN", "Default model", default_model)

    if task_model == "":
        add_line("OK", "Task model", "blank; tasks use the current chat model")
    else:
        add_line(
            "WARN",
            "Task model",
            f"{task_model} can evict the active chat model after title/tag tasks",
        )

    params = read_default_model_params(compose_text)
    stream_safe = bool(params and params.get("stream_response"))
    keep_alive = str(params.get("keep_alive") if params else "")
    keep_ok = bool(keep_alive) and keep_alive not in {"0", "0s", "0m"}
    global_think_off = bool(params and params.get("think") is False)
    if stream_safe and keep_ok:
        if global_think_off:
            add_line(
                "WARN",
                "Render safety",
                f"remove global think=false; request keep_alive={keep_alive}",
            )
        else:
            add_line(
                "OK",
                "Render safety",
                f"stream_response=true; request keep_alive={keep_alive}",
            )
    else:
        missing = []
        if not stream_safe:
            missing.append("stream_response=true")
        if not keep_ok:
            missing.append("request keep_alive=30m")
        add_line("WARN", "Render safety", "missing: " + ", ".join(missing))

    if re.search(r"(?m)^\s*-\s*ENABLE_MEMORIES=True\s*$", compose_text):
        add_line(
            "OK",
            "Open WebUI memories",
            "enabled; think-light uses per-model think=false",
        )
    else:
        add_line(
            "WARN",
            "Open WebUI memories",
            "ENABLE_MEMORIES=True missing; memory tools may be unavailable",
        )


def check_open_webui_thinking(add_line: AddLine) -> None:
    # Opens the live DB read-only (mode=ro, no immutable) with a busy timeout and
    # guards the schema before querying, so a future Open WebUI migration shows a
    # distinct "unsupported schema" WARN instead of a misleading failure (#8).
    # exit 0=good, 1=misconfigured rows, 2=unsupported schema, 3=cannot open.
    code = """
import json
import sqlite3
import sys

uri = "file:/app/backend/data/webui.db?mode=ro"
try:
    con = sqlite3.connect(uri, uri=True, timeout=4)
except sqlite3.OperationalError as exc:
    print("OPEN: " + str(exc))
    sys.exit(3)
con.row_factory = sqlite3.Row
con.execute("PRAGMA busy_timeout=4000")
q = "select name from sqlite_master where type='table' and name='model'"
if con.execute(q).fetchone() is None:
    print("SCHEMA: no model table")
    con.close()
    sys.exit(2)
cols = {r[1] for r in con.execute("pragma table_info(model)").fetchall()}
if not {"id", "params"} <= cols:
    print("SCHEMA: model table missing id/params")
    con.close()
    sys.exit(2)
think_light = [
    "qwen3.6-thinklight-grounded:latest",
    "deep-thinking-qwen3.6:latest",
    "web-search-deep-qwen3.6:latest",
]
full = [
    "qwen3.6-35b-a3b-grounded:latest",
    "full-thinking-qwen3.6:latest",
]
bad = []
for model in think_light:
    row = con.execute("select params from model where id=?", (model,)).fetchone()
    params = json.loads((row or {"params": "{}"})["params"] or "{}")
    if params.get("think") is not False:
        bad.append(model + " missing think=false")
for model in full:
    row = con.execute("select params from model where id=?", (model,)).fetchone()
    params = json.loads((row or {"params": "{}"})["params"] or "{}")
    if params.get("think") is False:
        bad.append(model + " should think")
con.close()
print("; ".join(bad))
sys.exit(1 if bad else 0)
""".strip()
    result = compose.compose_exec(
        "open-webui", ["python", "-c", code], timeout_sec=20
    )
    text = result.text.strip()
    if result.code == 0:
        add_line(
            "OK", "Open WebUI thinking", "think=false only on Qwen3.6 think-light rows"
        )
    elif result.code == 1:
        add_line(
            "WARN",
            "Open WebUI thinking",
            f"run ai-openwebui-thinklight.ps1; {text}",
        )
    elif result.code == 2:
        add_line(
            "WARN",
            "Open WebUI thinking",
            "unsupported Open WebUI schema; skipped think-light check",
        )
    else:
        add_line(
            "WARN",
            "Open WebUI thinking",
            f"Open WebUI unavailable; think-light check skipped ({text})",
        )


@dataclass(frozen=True)
class SmokeResult:
    ok: bool
    detail: str


def smoke_open_webui_reaches_ollama(*, timeout_sec: int = 20) -> SmokeResult:
    """L4: can the Open WebUI container reach the Ollama API and see models?"""
    code = (
        "import json, sys, urllib.request;"
        "u='http://host.docker.internal:11434/api/tags';"
        "d=json.load(urllib.request.urlopen(u, timeout=8));"
        "m=d.get('models', []);"
        "print(len(m));"
        "sys.exit(0 if m else 1)"
    )
    result = compose.compose_exec(
        "open-webui", ["python", "-c", code], timeout_sec=timeout_sec
    )
    text = result.text.strip()
    if result.code == 0:
        return SmokeResult(True, f"{text} models visible from the container")
    return SmokeResult(False, text or "Open WebUI cannot reach Ollama")


def smoke_tiny_inference(model: str, *, timeout_sec: int = 60) -> SmokeResult:
    """L5: a 1-token generation through Ollama on the host."""
    body = json.dumps(
        {
            "model": model,
            "prompt": "ping",
            "stream": False,
            "options": {"num_predict": 1},
            "keep_alive": "30m",
        }
    ).encode("utf-8")
    request = Request(
        "http://127.0.0.1:11434/api/generate",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urlopen(request, timeout=timeout_sec) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except (OSError, TimeoutError, URLError, json.JSONDecodeError) as exc:
        return SmokeResult(False, str(exc))
    text = str(payload.get("response", "")) if isinstance(payload, dict) else ""
    if text:
        return SmokeResult(True, f"generated {len(text)} chars")
    return SmokeResult(False, "empty response")


def check_open_webui_reaches_ollama(add_line: AddLine) -> None:
    # WARN (not FAIL) when the container is down - that is the prerequisite, not a
    # broken stack; FAIL only when it is up but cannot reach Ollama.
    if compose.compose_service_status("open-webui") is None:
        add_line("WARN", "Open WebUI->Ollama", "Open WebUI not running; skipped")
        return
    smoke = smoke_open_webui_reaches_ollama()
    add_line("OK" if smoke.ok else "FAIL", "Open WebUI->Ollama", smoke.detail)


def check_tiny_inference(add_line: AddLine, default_model: str) -> None:
    smoke = smoke_tiny_inference(default_model)
    status = "OK" if smoke.ok else "WARN"
    add_line(status, "Inference smoke", f"{default_model}: {smoke.detail}")


def check_terminal_launchers(add_line: AddLine) -> None:
    names = (
        "Start-TerminalAI.ps1",
        "Stop-LocalAI.ps1",
        "Stop-AI-For-Gaming.ps1",
        "Terminal-Code.bat",
        "Terminal-DeepCode.bat",
        "Stop-LocalAI.bat",
        "AI-Game-Mode.bat",
    )
    missing = [name for name in names if not repo_path(name).exists()]
    if missing:
        add_line("WARN", "Terminal launchers", "missing: " + ", ".join(missing))
    else:
        add_line("OK", "Terminal launchers", f"{len(names)} scripts present")


def check_terminal_commands(add_line: AddLine) -> None:
    user_profile = os.environ.get("USERPROFILE", "")
    bin_dir = Path(user_profile) / ".local" / "bin"
    names = (
        "ai.cmd",
        "ai-chat.cmd",
        "ai-deepchat.cmd",
        "ai-doctor.cmd",
        "ai-code.cmd",
        "ai-deepcode.cmd",
        "ai-web.cmd",
        "ai-vision.cmd",
        "ai-image.cmd",
        "ai-start.cmd",
        "ai-game-mode.cmd",
        "ai-models.cmd",
    )
    missing = [name for name in names if not (bin_dir / name).exists()]
    if missing:
        add_line("WARN", "Terminal commands", "missing: " + ", ".join(missing))
    else:
        add_line("OK", "Terminal commands", f"{len(names)} ai-* commands present")


def check_node_smoke(
    add_line: AddLine,
    name: str,
    script: str,
    ok_marker: str,
    ok_detail: str,
    *,
    timeout_sec: int = 30,
) -> None:
    node = Path(os.environ.get("PROGRAMFILES", "")) / "nodejs" / "node.exe"
    script_path = repo_path(script)
    if not node.exists() or not script_path.exists():
        add_line("WARN", name, f"node.exe or {script} missing")
        return
    result = run_command(
        [str(node), str(script_path)], cwd=REPO_ROOT, timeout_sec=timeout_sec
    )
    text = normalize_whitespace(result.text)
    if result.code == 0 and ok_marker in result.text:
        add_line("OK", name, ok_detail)
    else:
        add_line("WARN", name, text)


def check_nanobrowser(add_line: AddLine, default_model: str) -> None:
    script = repo_path("test-browser-ai-provider.ps1")
    if not script.exists():
        add_line("WARN", "Nanobrowser Ollama", "test-browser-ai-provider.ps1 missing")
        return
    result = run_command(
        [
            "pwsh",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(script),
            "-Model",
            default_model,
            "-SkipChat",
            "-NativeTimeoutSec",
            "25",
            "-NativeNumPredict",
            "8",
        ],
        cwd=REPO_ROOT,
        timeout_sec=35,
    )
    text = result.text
    if (
        result.code == 0
        and "Browser extension origin: OK" in text
        and "Native Ollama structured output: OK" in text
    ):
        add_line(
            "OK", "Nanobrowser Ollama", "origin + native /api/chat structured output OK"
        )
    else:
        add_line("WARN", "Nanobrowser Ollama", normalize_whitespace(text))


def check_cherry_agent(add_line: AddLine) -> None:
    script = repo_path("test-cherry-agent.ps1")
    cherry = (
        Path(os.environ.get("LOCALAPPDATA", ""))
        / "Programs"
        / "Cherry Studio"
        / "Cherry Studio.exe"
    )
    if not script.exists():
        add_line("WARN", "Cherry agent", "test-cherry-agent.ps1 missing")
        return
    result = run_command(
        ["pwsh", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script)],
        cwd=REPO_ROOT,
        timeout_sec=30,
    )
    text = result.text
    if result.code == 0 and "Cherry agent test: OK" in text:
        add_line("OK", "Cherry agent", "Local Claude Desktop tool-forward agent")
    elif "Cherry API key not found" in text:
        fallback = run_command(
            [
                "pwsh",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(script),
                "-AllowLogApiKeyFallback",
            ],
            cwd=REPO_ROOT,
            timeout_sec=30,
        )
        if fallback.code == 0 and "Cherry agent test: OK" in fallback.text:
            add_line(
                "OK",
                "Cherry agent",
                "Local Claude Desktop tool-forward agent "
                "(API key read from local Cherry logs)",
            )
        else:
            add_line("WARN", "Cherry agent", normalize_whitespace(fallback.text))
    elif "local API is not reachable" in text and cherry.exists():
        add_line("OK", "Cherry agent", "optional launcher present; not running")
    else:
        add_line("WARN", "Cherry agent", normalize_whitespace(text))


def check_ollama(add_line: AddLine, default_model: str) -> None:
    ollama = ollama_path()
    try:
        listing = run_command([str(ollama), "list"], cwd=REPO_ROOT, timeout_sec=30)
        if listing.code != 0:
            raise RuntimeError(listing.text)
        model_names = parse_ollama_list_names(listing.text)
        missing = [name for name in EXPECTED_ALIASES if name not in model_names]
        if missing:
            add_line("WARN", "Dropdown aliases", "missing: " + ", ".join(missing))
        else:
            add_line(
                "OK",
                "Dropdown aliases",
                f"{len(EXPECTED_ALIASES)} purpose names present",
            )

        ps_result = run_command([str(ollama), "ps"], cwd=REPO_ROOT, timeout_sec=20)
        if ps_result.code != 0:
            raise RuntimeError(ps_result.text)
        rows = [line for line in ps_result.text.splitlines() if line.strip()]
        warm_names = [default_model]
        if default_model in ALIAS_SOURCES:
            warm_names.append(ALIAS_SOURCES[default_model])
        loaded = next(
            (line for line in rows if any(name in line for name in warm_names)), None
        )
        if loaded:
            add_line("OK", "Ollama warm model", loaded.strip())
        else:
            other_loaded = [line.split()[0] for line in rows[1:] if line.split()]
            if other_loaded:
                add_line(
                    "WARN",
                    "Ollama warm model",
                    f"{default_model} is not loaded; loaded: {', '.join(other_loaded)}",
                )
            else:
                add_line("WARN", "Ollama warm model", f"{default_model} is not loaded")
    except (OSError, RuntimeError, ValueError):
        add_line("FAIL", "Ollama", "not reachable")


def parse_ollama_list_names(text: str) -> set[str]:
    names: set[str] = set()
    for line in text.splitlines()[1:]:
        parts = line.split()
        if not parts:
            continue
        name = parts[0].strip()
        if name:
            names.add(name)
            names.add(name.removesuffix(":latest"))
    return names


def check_searxng(add_line: AddLine) -> None:
    if not tcp_open("127.0.0.1", 8080, timeout_sec=1):
        add_line("FAIL", "SearXNG search", "service not reachable on 8080")
        return
    try:
        payload = request_json(
            "http://127.0.0.1:8080/search?q=open+webui&format=json", timeout_sec=8
        )
        results = payload.get("results") if isinstance(payload, dict) else []
        count = len(results) if isinstance(results, list) else 0
        if count > 0:
            add_line("OK", "SearXNG search", f"{count} results")
        else:
            add_line("WARN", "SearXNG search", "0 results")
    except (OSError, TimeoutError, URLError, json.JSONDecodeError):
        add_line("FAIL", "SearXNG search", "query failed")


def check_kokoro(add_line: AddLine) -> None:
    if not tcp_open("127.0.0.1", 8880, timeout_sec=1):
        add_line("FAIL", "Kokoro TTS", "service not reachable on 8880")
        return
    tmp = Path(tempfile.gettempdir()) / "kokoro-health.mp3"
    body = (
        b'{"model":"kokoro","input":"Local voice check.",'
        b'"voice":"am_michael","response_format":"mp3"}'
    )
    try:
        request = Request(
            "http://127.0.0.1:8880/v1/audio/speech",
            data=body,
            method="POST",
            headers={"Content-Type": "application/json"},
        )
        with urlopen(request, timeout=15) as response:
            tmp.write_bytes(response.read())
        size = tmp.stat().st_size if tmp.exists() else 0
        tmp.unlink(missing_ok=True)
        if size > 1000:
            add_line("OK", "Kokoro TTS", f"{size} bytes mp3")
        else:
            add_line("WARN", "Kokoro TTS", "response too small")
    except (OSError, TimeoutError, URLError):
        tmp.unlink(missing_ok=True)
        add_line("FAIL", "Kokoro TTS", "speech request failed")


def check_image_studio(add_line: AddLine) -> None:
    if tcp_open("127.0.0.1", 8188, timeout_sec=1):
        add_line("OK", "Image studio", "ComfyUI reachable on 8188")
    elif (
        Path(os.environ.get("USERPROFILE", "")) / "imageai" / "Start-Image-Studio.bat"
    ).exists():
        add_line("OK", "Image studio", "optional launcher present; not running")
    else:
        add_line("WARN", "Image studio", "optional; launcher not found")


def check_gpu_memory(add_line: AddLine) -> None:
    result = run_command(
        [
            "nvidia-smi",
            "--query-gpu=memory.used,memory.total",
            "--format=csv,noheader,nounits",
        ],
        cwd=REPO_ROOT,
        timeout_sec=15,
    )
    if result.code != 0 or not result.text.strip():
        add_line("WARN", "GPU memory", "nvidia-smi returned nothing")
        return
    try:
        first = result.text.splitlines()[0]
        used_mb, total_mb = [float(part.strip()) for part in first.split(",", 1)]
    except ValueError:
        add_line("WARN", "GPU memory", "nvidia-smi returned nothing")
        return
    used_gb = round(used_mb / 1024, 1)
    total_gb = round(total_mb / 1024, 1)
    free_gb = round((total_mb - used_mb) / 1024, 1)
    if free_gb < 0.8:
        detail = (
            f"{format_number(used_gb)}/{format_number(total_gb)} GB used, "
            f"only {format_number(free_gb)} GB free "
            "(close GPU apps before heavy runs)"
        )
        add_line(
            "WARN",
            "GPU memory",
            detail,
        )
    else:
        detail = (
            f"{format_number(used_gb)}/{format_number(total_gb)} GB used, "
            f"{format_number(free_gb)} GB free"
        )
        add_line(
            "OK",
            "GPU memory",
            detail,
        )


def check_firewall(add_line: AddLine) -> None:
    try:
        block_rule = firewall.get_netsh_firewall_rule(firewall.PHYSICAL_BLOCK_RULE_NAME)
        has_block = bool(
            block_rule
            and block_rule.enabled == "Yes"
            and block_rule.action == "Block"
            and block_rule.protocol == "TCP"
        )
        missing = []
        if has_block and block_rule is not None:
            missing = [
                port
                for port in LOCALAI_PORTS
                if not firewall.port_spec_contains(block_rule.local_port, port)
            ]
        else:
            missing = list(LOCALAI_PORTS)

        if has_block and not missing:
            add_line(
                "OK",
                "Physical port block",
                "LocalAI ports blocked on physical network adapters",
            )
        elif has_block:
            add_line(
                "WARN",
                "Physical port block",
                "block rule missing port(s): "
                + ", ".join(str(port) for port in missing)
                + "; run ai-firewall.ps1 -Apply",
            )
        else:
            add_line(
                "WARN",
                "Physical port block",
                "missing; run ai-firewall.ps1 -Apply from elevated PowerShell",
            )

        rows = firewall.get_inbound_allow_rows(LOCALAI_PORTS)
        leak_ports = sorted({row.port for row in rows})
        if not leak_ports:
            add_line(
                "OK", "Firewall exposure", "no inbound allow rules for localai ports"
            )
        else:
            details = []
            for port in leak_ports:
                rule = next(row.rule_name for row in rows if row.port == port)
                if len(rule) > 42:
                    rule = rule[:39] + "..."
                details.append(f"{port} via {rule}")
            if has_block and not missing:
                add_line(
                    "OK",
                    "Firewall exposure",
                    "third-party allow rules physically blocked: " + "; ".join(details),
                )
            else:
                add_line(
                    "WARN",
                    "Firewall exposure",
                    "inbound localai ports: "
                    + "; ".join(details)
                    + " - run ai-firewall.ps1 -Apply",
                )
    except (OSError, RuntimeError) as exc:
        add_line("WARN", "Firewall scan", str(exc))


def check_git_secret_guard(add_line: AddLine) -> None:
    result = run_command(
        ["git", "config", "--global", "core.hooksPath"], cwd=REPO_ROOT, timeout_sec=10
    )
    path_text = (
        result.text.splitlines()[0].strip()
        if result.code == 0 and result.text.strip()
        else ""
    )
    guard = Path(path_text) / "pre-commit" if path_text else Path()
    if guard.exists() and "secret-guard" in guard.read_text(
        encoding="utf-8", errors="ignore"
    ):
        add_line("OK", "Git secret-guard", "global pre-commit hook active")
    else:
        add_line(
            "WARN", "Git secret-guard", "global pre-commit secret-guard not installed"
        )


def http_code(url: str, *, timeout_sec: int) -> int:
    try:
        with urlopen(url, timeout=timeout_sec) as response:
            return int(response.status)
    except (OSError, TimeoutError, URLError):
        return 0


def request_json(url: str, *, timeout_sec: int) -> object:
    with urlopen(url, timeout=timeout_sec) as response:
        return json.loads(response.read().decode("utf-8"))


def tcp_open(host: str, port: int, *, timeout_sec: float) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout_sec):
            return True
    except OSError:
        return False
