"""Privacy-safe diagnostic report a novice can paste to whoever set this up.

Design rule: this is an ALLOW-LIST, not a dump. Every field below is written
out by name from a known collector. Nothing iterates os.environ, reads .env,
touches the Open WebUI volume, or walks the user's files - so chats, documents,
prompts, API tokens and secrets cannot reach the report by construction rather
than by filtering after the fact.

The one residual leak channel is free text that a collector happens to embed
(a path in an error message, a Windows profile directory). Every string that
leaves this module therefore passes through ``scrub`` exactly once, at the
single emission point in ``format_report``.
"""

from __future__ import annotations

import os
import platform
import re
import shutil
import sys
from pathlib import Path
from typing import Any

from localai import __version__
from localai.ops import run_command
from localai.paths import REPO_ROOT

#: Hard ceiling so a novice can paste this into a chat window.
MAX_REPORT_CHARS = 8000
#: Recent error lines are useful but unbounded output is not.
MAX_ERROR_LINES = 12
MAX_ERROR_LINE_CHARS = 200

_REDACTED_USER = "<user>"
_REDACTED_HOME = r"<home>"


def _home_candidates() -> list[str]:
    """Directory prefixes that identify this machine's owner."""
    seen: list[str] = []
    for value in (
        os.environ.get("USERPROFILE"),
        str(Path.home()) if _safe_home() else None,
        os.environ.get("APPDATA"),
        os.environ.get("LOCALAPPDATA"),
    ):
        if value and value not in seen:
            seen.append(value)
    # Longest first so C:\Users\bob\AppData\Local is replaced before C:\Users\bob.
    return sorted(seen, key=len, reverse=True)


def _safe_home() -> bool:
    try:
        Path.home()
    except (RuntimeError, OSError):
        return False
    return True


def _usernames() -> list[str]:
    names: list[str] = []
    for value in (os.environ.get("USERNAME"), os.environ.get("USER")):
        # Guard against a 1-2 char username scrubbing unrelated text.
        if value and len(value) >= 3 and value not in names:
            names.append(value)
    return names


def scrub(text: str) -> str:
    """Remove machine-owner identity from a string bound for the report.

    Replaces home/AppData directory prefixes and the account name. Applied to
    every emitted line, including ones this module did not author (error text
    from Docker, Ollama or Python tracebacks).
    """
    if not text:
        return text
    out = text
    for home in _home_candidates():
        out = out.replace(home, _REDACTED_HOME)
        # Windows paths reach us in both separator styles and both cases.
        out = out.replace(home.replace("\\", "/"), _REDACTED_HOME)
        out = re.sub(re.escape(home), _REDACTED_HOME, out, flags=re.IGNORECASE)
    for name in _usernames():
        out = re.sub(
            rf"(?<![A-Za-z0-9]){re.escape(name)}(?![A-Za-z0-9])",
            _REDACTED_USER,
            out,
            flags=re.IGNORECASE,
        )
    # Backstop for any C:\Users\<somebody> that survived the prefix pass
    # (e.g. a path belonging to a different profile on the same box).
    out = re.sub(
        r"([A-Za-z]:[\\/]+Users[\\/]+)[^\\/\r\n\"']+",
        rf"\1{_REDACTED_USER}",
        out,
    )
    return out


def _windows_build() -> str:
    try:
        return f"{platform.system()} {platform.release()} (build {platform.version()})"
    except OSError:
        return "unknown"


def _cpu_name() -> str:
    name = (platform.processor() or "").strip()
    if name:
        return name
    return platform.machine() or "unknown"


def _disk_free_gb() -> float | None:
    try:
        return round(
            shutil.disk_usage(str(REPO_ROOT.anchor or REPO_ROOT)).free / 1024**3, 1
        )
    except OSError:
        return None


def _gpu_name() -> str | None:
    """GPU model name via nvidia-smi, mirroring system_info's probe style."""
    try:
        result = run_command(
            ["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"],
            cwd=REPO_ROOT,
            timeout_sec=8,
        )
    except Exception:  # noqa: BLE001 - absent driver must not break support
        return None
    if getattr(result, "code", 1) != 0:
        return None
    first = (getattr(result, "stdout", "") or "").strip().splitlines()
    return first[0].strip() if first and first[0].strip() else None


def _hardware_from_hwcaps() -> dict[str, Any] | None:
    """Rich probe, when the portable capability module is present.

    hwcaps ships on the portable-hardware branch, not on the shipping
    baseline, so this is optional by design: absent it, the report falls back
    to system_info below and stays useful. When hwcaps does land, diagnostics
    picks it up with no further change.
    """
    # Imported dynamically on purpose. hwcaps is absent from this baseline but
    # present on a dev box via a shadowing editable install, so a static import
    # needs a different type:ignore in each environment and `strict = true`
    # rejects whichever one is unused. importlib sidesteps that entirely.
    import importlib

    try:
        probe_hardware = importlib.import_module("localai.hwcaps").probe_hardware
    except (ImportError, AttributeError):
        return None
    try:
        data = probe_hardware().to_dict()
    except Exception as exc:  # noqa: BLE001 - a probe must not break support
        return {"error": f"{type(exc).__name__}: {exc}"}
    # Accelerator.to_dict emits "type"/"device_name".
    gpus = [
        {
            "name": item.get("device_name") or "unknown",
            "vram_gb": item.get("dedicated_memory_gb") or item.get("unified_memory_gb"),
        }
        for item in data.get("accelerators", [])
        if item.get("type") == "gpu"
    ]
    return {
        "source": "hwcaps",
        "os": data.get("operating_system"),
        "arch": data.get("architecture"),
        "cpu": data.get("cpu_identity") or _cpu_name(),
        "ram_gb": data.get("total_memory_gb"),
        "gpus": gpus,
        "selected_runtime": (data.get("selected_runtime") or {}).get("backend"),
        "warnings": data.get("warnings", []),
    }


def _hardware_from_system_info() -> dict[str, Any]:
    """CPU / RAM / GPU from the collector that ships on the shipping baseline."""
    try:
        from localai.system_info import collect_system

        info = collect_system()
    except Exception as exc:  # noqa: BLE001 - a probe must not break support
        return {"source": "none", "error": f"{type(exc).__name__}: {exc}"}
    name = _gpu_name()
    vram = info.get("vramTotalGb")
    gpus = [{"name": name or "unknown", "vram_gb": vram}] if (name or vram) else []
    return {
        "source": "system_info",
        "os": platform.system(),
        "arch": platform.machine(),
        "cpu": _cpu_name(),
        "ram_gb": info.get("ramTotalGb"),
        "gpus": gpus,
        "selected_runtime": "cuda" if gpus else "cpu",
        "warnings": [],
    }


def _hardware() -> dict[str, Any]:
    """CPU / RAM / GPU. Prefers hwcaps; falls back to system_info. Never fatal."""
    rich = _hardware_from_hwcaps()
    if rich is not None and not rich.get("error"):
        return rich
    fallback = _hardware_from_system_info()
    if rich is not None and rich.get("error"):
        fallback["warnings"] = [f"hwcaps probe failed: {rich['error']}"]
    return fallback


def _installer_state() -> dict[str, Any]:
    """Which phases finished, the vetted tier, and the picked model.

    Reads only the named keys; the file is written by the installer and holds
    no user content, but an allow-list keeps that true if it ever grows.
    """
    path = REPO_ROOT / "installer" / "installer-state.json"
    if not path.is_file():
        return {"present": False}
    try:
        import json

        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        return {"present": True, "error": f"unreadable: {type(exc).__name__}: {exc}"}
    hardware = raw.get("hardware") or {}
    models = raw.get("models") or {}
    chat = models.get("chat") or {}
    return {
        "present": True,
        "phases_done": raw.get("phases_done") or [],
        "pending_reboot": bool(raw.get("pending_reboot")),
        "tier": hardware.get("tier") if isinstance(hardware, dict) else None,
        "vram_budget_gb": (
            hardware.get("vram_gb") if isinstance(hardware, dict) else None
        ),
        "model_tag": chat.get("tag") if isinstance(chat, dict) else None,
        "model_num_ctx": chat.get("num_ctx") if isinstance(chat, dict) else None,
    }


def _command_status(argv: list[str], *, timeout_sec: int = 20) -> dict[str, Any]:
    """Run a read-only status command; report reachability, never raise."""
    try:
        result = run_command(argv, timeout_sec=timeout_sec)
    except Exception as exc:  # noqa: BLE001 - absent tool must not break support
        return {"ok": False, "detail": f"{type(exc).__name__}: {exc}"}
    code = getattr(result, "code", None)
    text = (getattr(result, "stdout", "") or "").strip()
    err = (getattr(result, "stderr", "") or "").strip()
    detail = text or err
    return {
        "ok": code == 0,
        "detail": detail.splitlines()[0][:MAX_ERROR_LINE_CHARS] if detail else "",
    }


def _docker_status() -> dict[str, Any]:
    return _command_status(["docker", "info", "--format", "{{.ServerVersion}}"])


def _ollama_status() -> dict[str, Any]:
    """Is the Ollama ENGINE actually serving?

    `ollama --version` exits 0 even when the daemon is down (observed live: it
    printed "Warning: could not connect to a running Ollama instance" and still
    returned 0), which made this report tell the owner "reachable" about a dead
    engine. Probe the API instead - that is the thing the product needs.
    """
    import urllib.error
    import urllib.request

    try:
        with urllib.request.urlopen(
            "http://127.0.0.1:11434/api/tags", timeout=5
        ) as resp:
            ok = 200 <= resp.status < 300
        return {"ok": ok, "detail": "" if ok else "unexpected HTTP status"}
    except (OSError, urllib.error.URLError, ValueError) as exc:
        return {
            "ok": False,
            "detail": f"{type(exc).__name__}: {exc}"[:MAX_ERROR_LINE_CHARS],
        }


#: A novice clicks a button and waits; the full health sweep (inference smoke
#: test, Tailscale, firewall enumeration) took over 120s on the dev box, which
#: is far too long for a support affordance. Bound it and say so when it trips.
HEALTH_TIMEOUT_SEC = 25


def _service_health() -> dict[str, Any]:
    """Core service health via the existing health collector, time-bounded."""
    import queue
    import threading

    result: queue.Queue[Any] = queue.Queue(maxsize=1)

    def _run() -> None:
        try:
            from localai.health import collect_health_report

            result.put(collect_health_report())
        except Exception as exc:  # noqa: BLE001
            result.put(exc)

    # Daemon thread: collect_health_report has no cancellation seam, so on
    # timeout we abandon it rather than block the report behind it.
    worker = threading.Thread(target=_run, daemon=True)
    worker.start()
    try:
        outcome = result.get(timeout=HEALTH_TIMEOUT_SEC)
    except queue.Empty:
        return {
            "ran": False,
            "detail": f"still running after {HEALTH_TIMEOUT_SEC}s - "
            "usually means Docker or Ollama is not up",
        }
    if isinstance(outcome, Exception):
        return {"ran": False, "detail": f"{type(outcome).__name__}: {outcome}"}
    code, lines = outcome
    problems = [
        line.strip()
        for line in lines
        if any(
            marker in line.upper() for marker in ("FAIL", "ERROR", "WARN", "MISSING")
        )
    ]
    return {
        "ran": True,
        "exit_code": code,
        "problem_lines": problems[:MAX_ERROR_LINES],
    }


def collect_report() -> dict[str, Any]:
    """Assemble the raw (un-scrubbed) report body. Callers must format it."""
    return {
        "afk_ai_version": __version__,
        "python": f"{sys.version_info.major}.{sys.version_info.minor}."
        f"{sys.version_info.micro}",
        "windows": _windows_build(),
        "hardware": _hardware(),
        "disk_free_gb": _disk_free_gb(),
        "installer": _installer_state(),
        "ollama": _ollama_status(),
        "docker": _docker_status(),
        "health": _service_health(),
    }


def _fmt(value: Any) -> str:
    if value is None:
        return "unknown"
    if isinstance(value, bool):
        return "yes" if value else "no"
    return str(value)


def format_report(report: dict[str, Any] | None = None) -> list[str]:
    """Render the report as scrubbed, paste-ready plain text.

    Every line leaving this function has passed ``scrub`` exactly once.
    """
    data = collect_report() if report is None else report
    hw = data.get("hardware") or {}
    inst = data.get("installer") or {}
    health = data.get("health") or {}

    lines: list[str] = [
        "AFK AI - diagnostic report",
        "(safe to send: no chats, documents, prompts, passwords or file contents)",
        "",
        f"AFK AI version : {_fmt(data.get('afk_ai_version'))}",
        f"Windows        : {_fmt(data.get('windows'))}",
        f"Python         : {_fmt(data.get('python'))}",
        "",
        "-- This PC --",
        f"CPU            : {_fmt(hw.get('cpu'))}",
        f"RAM            : {_fmt(hw.get('ram_gb'))} GB",
        f"Free disk      : {_fmt(data.get('disk_free_gb'))} GB",
    ]
    gpus = hw.get("gpus") or []
    if gpus:
        for gpu in gpus:
            lines.append(
                f"Graphics       : {_fmt(gpu.get('name'))} "
                f"({_fmt(gpu.get('vram_gb'))} GB video memory)"
            )
    else:
        lines.append("Graphics       : none detected (running on the CPU)")
    if hw.get("selected_runtime"):
        lines.append(f"Using          : {_fmt(hw.get('selected_runtime'))}")
    if hw.get("error"):
        lines.append(f"Hardware probe : failed - {_fmt(hw.get('error'))}")

    lines += [
        "",
        "-- Setup state --",
        f"Installer ran  : {_fmt(inst.get('present'))}",
    ]
    if inst.get("present"):
        done = inst.get("phases_done") or []
        lines += [
            f"Phases done    : {', '.join(done) if done else 'none'}",
            f"Awaiting restart: {_fmt(inst.get('pending_reboot'))}",
            f"Capability tier: {_fmt(inst.get('tier'))}",
            f"VRAM budget    : {_fmt(inst.get('vram_budget_gb'))} GB",
            f"Chosen model   : {_fmt(inst.get('model_tag'))} "
            f"(context {_fmt(inst.get('model_num_ctx'))})",
        ]
    if inst.get("error"):
        lines.append(f"Setup state    : {_fmt(inst.get('error'))}")

    ollama = data.get("ollama") or {}
    docker = data.get("docker") or {}
    lines += [
        "",
        "-- Services --",
        f"Ollama         : {'reachable' if ollama.get('ok') else 'NOT reachable'}"
        + (f" - {ollama.get('detail')}" if ollama.get("detail") else ""),
        f"Docker         : {'running' if docker.get('ok') else 'NOT running'}"
        + (f" - {docker.get('detail')}" if docker.get("detail") else ""),
    ]
    if health.get("ran"):
        lines.append(f"Health check   : exit {_fmt(health.get('exit_code'))}")
        problems = health.get("problem_lines") or []
        if problems:
            lines.append("Recent problems:")
            lines += [f"  {line[:MAX_ERROR_LINE_CHARS]}" for line in problems]
        else:
            lines.append("Recent problems: none")
    else:
        lines.append(f"Health check   : did not run - {_fmt(health.get('detail'))}")

    scrubbed = [scrub(line) for line in lines]
    text = "\n".join(scrubbed)
    if len(text) > MAX_REPORT_CHARS:
        keep: list[str] = []
        size = 0
        for line in scrubbed:
            if size + len(line) + 1 > MAX_REPORT_CHARS - 40:
                keep.append("... (report truncated)")
                break
            keep.append(line)
            size += len(line) + 1
        return keep
    return scrubbed


def copy_to_clipboard(text: str) -> bool:
    """Best-effort clipboard copy so a novice never has to select text.

    Uses Windows ``clip`` directly rather than ops.run_command, which has no
    stdin channel. Failure is non-fatal: the caller still prints the report.
    """
    import subprocess

    try:
        completed = subprocess.run(
            ["clip"],
            input=text,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return completed.returncode == 0


def save_report(lines: list[str], path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path
