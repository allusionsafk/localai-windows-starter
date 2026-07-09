"""Read-only power guard ported from ai-power.ps1."""

from __future__ import annotations

import ctypes
import json
import re
from dataclasses import dataclass
from datetime import datetime
from urllib.error import URLError
from urllib.request import urlopen

from localai.ops import run_command
from localai.paths import REPO_ROOT


@dataclass(frozen=True)
class PowerState:
    has_battery: bool
    on_battery: bool
    charge: int | None
    detail: str


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


def collect_power_report(
    *,
    strict: bool = False,
    timeout_sec: int = 8,
    now: datetime | None = None,
) -> tuple[int, list[str]]:
    """Collect the same read-only checks as ai-power.ps1."""
    counters = Counters()
    stamp = (now or datetime.now()).strftime("%Y-%m-%d %H:%M:%S")
    lines = [f"==== localai power guard ====  {stamp}"]

    def add_line(status: str, name: str, detail: str) -> None:
        counters.add(status)
        lines.append(format_status_line(status, name, detail))

    power = get_power_state()
    if not power.has_battery:
        add_line("OK", "Power source", power.detail)
    elif power.on_battery:
        if power.charge is not None and power.charge <= 20:
            add_line(
                "WARN",
                "Power source",
                f"{power.detail}; consider stopping LocalAI",
            )
        else:
            add_line("WARN", "Power source", power.detail)
    else:
        add_line("OK", "Power source", power.detail)

    models = get_loaded_ollama_models()
    if not models:
        add_line("OK", "Ollama models", "none loaded")
    elif power.on_battery:
        add_line("WARN", "Ollama models", f"loaded on battery: {', '.join(models)}")
    else:
        add_line("OK", "Ollama models", f"loaded: {', '.join(models)}")

    container_state = get_localai_container_state(timeout_sec)
    if container_state.code != 0:
        detail = (
            container_state.detail
            if container_state.detail
            else f"docker ps exit {container_state.code}"
        )
        add_line("WARN", "Docker containers", f"check unavailable: {detail}")
    elif not container_state.rows:
        add_line("OK", "Docker containers", "no localai containers running")
    elif power.on_battery:
        add_line(
            "WARN",
            "Docker containers",
            f"{len(container_state.rows)} localai container(s) running on battery",
        )
    else:
        add_line(
            "OK",
            "Docker containers",
            f"{len(container_state.rows)} localai container(s) running",
        )

    gpu = get_gpu_state(timeout_sec)
    if gpu is None:
        add_line("OK", "GPU load", "nvidia-smi unavailable or no NVIDIA GPU reported")
    else:
        used_mb, total_mb, util = gpu
        used_gb = round(used_mb / 1024, 1)
        total_gb = round(total_mb / 1024, 1)
        detail = (
            f"{format_number(used_gb)}/{format_number(total_gb)} GB used, "
            f"{format_number(util)}% utilization"
        )
        if power.on_battery and (used_mb >= 4096 or util >= 10):
            add_line("WARN", "GPU load", detail)
        else:
            add_line("OK", "GPU load", detail)

    warm_state = get_ai_warm_state(timeout_sec)
    if power.on_battery and warm_state == "Ready":
        add_line(
            "WARN",
            "AI-Warm task",
            "enabled; Game Mode can disable it before travel/gaming",
        )
    else:
        add_line("OK", "AI-Warm task", warm_state)

    lines.append("")
    lines.append(
        f"Summary: {counters.ok} OK, {counters.warn} WARN, {counters.fail} FAIL"
    )

    if power.on_battery and counters.warn > 0:
        lines.extend(
            [
                "",
                "Battery saver options:",
                "  pwsh -File Stop-LocalAI.ps1",
                "  pwsh -File Stop-AI-For-Gaming.ps1 -DisableWarmTask",
            ]
        )

    if counters.fail > 0:
        return 1, lines
    if strict and counters.warn > 0:
        return 1, lines
    return 0, lines


def format_status_line(status: str, name: str, detail: str) -> str:
    return f"[{status}] {name:<22} {detail}"


def get_power_state() -> PowerState:
    native = get_system_power_status()
    if native is None or native["battery_flag"] & 128:
        return PowerState(False, False, None, "no battery detected")

    charge = native["battery_life_percent"]
    charge_value = None if charge == 255 else int(charge)
    on_battery = native["ac_line_status"] == 0
    if on_battery:
        state = "discharging"
    elif native["ac_line_status"] == 1:
        state = "plugged in or full"
    else:
        state = "power state unknown"
    detail = (
        f"{state}, {charge_value}% remaining" if charge_value is not None else state
    )
    return PowerState(True, on_battery, charge_value, detail)


def get_system_power_status() -> dict[str, int] | None:
    try:
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    except AttributeError:
        return None

    class SystemPowerStatus(ctypes.Structure):
        _fields_ = [
            ("ACLineStatus", ctypes.c_ubyte),
            ("BatteryFlag", ctypes.c_ubyte),
            ("BatteryLifePercent", ctypes.c_ubyte),
            ("SystemStatusFlag", ctypes.c_ubyte),
            ("BatteryLifeTime", ctypes.c_int),
            ("BatteryFullLifeTime", ctypes.c_int),
        ]

    status = SystemPowerStatus()
    if not kernel32.GetSystemPowerStatus(ctypes.byref(status)):
        return None
    return {
        "ac_line_status": int(status.ACLineStatus),
        "battery_flag": int(status.BatteryFlag),
        "battery_life_percent": int(status.BatteryLifePercent),
    }


def get_loaded_ollama_models() -> list[str]:
    try:
        with urlopen("http://localhost:11434/api/ps", timeout=3) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except (OSError, TimeoutError, URLError, json.JSONDecodeError):
        return []

    models = []
    for row in payload.get("models", []):
        name = row.get("name") or row.get("model")
        if name:
            models.append(str(name))
    return models


@dataclass(frozen=True)
class ContainerState:
    code: int
    rows: list[str]
    detail: str


def get_localai_container_state(timeout_sec: int) -> ContainerState:
    result = run_command(
        ["docker", "ps", "--format", "{{.Names}}\\t{{.Status}}"],
        cwd=REPO_ROOT,
        timeout_sec=timeout_sec,
    )
    text = result.text.strip()
    if result.code != 0:
        return ContainerState(result.code, [], text)

    rows = [line for line in re.split(r"\r?\n", text) if line.startswith("localai-")]
    return ContainerState(0, rows, "")


def get_gpu_state(timeout_sec: int) -> tuple[float, float, float] | None:
    result = run_command(
        [
            "nvidia-smi",
            "--query-gpu=memory.used,memory.total,utilization.gpu",
            "--format=csv,noheader,nounits",
        ],
        cwd=REPO_ROOT,
        timeout_sec=timeout_sec,
    )
    text = result.text.strip()
    if result.code != 0 or not text:
        return None

    first = re.split(r"\r?\n", text)[0]
    parts = [part.strip() for part in first.split(",")]
    if len(parts) < 3:
        return None
    try:
        return float(parts[0]), float(parts[1]), float(parts[2])
    except ValueError:
        return None


def get_ai_warm_state(timeout_sec: int) -> str:
    result = run_command(
        ["schtasks", "/Query", "/TN", "AI-Warm", "/FO", "LIST"],
        cwd=REPO_ROOT,
        timeout_sec=timeout_sec,
    )
    text = result.text.strip()
    if result.code != 0:
        if "cannot find" in text.lower() or "does not exist" in text.lower():
            return "not installed"
        return "unknown"
    return parse_schtasks_status(text) or "unknown"


def parse_schtasks_status(text: str) -> str | None:
    for line in re.split(r"\r?\n", text):
        key, separator, value = line.partition(":")
        if separator and key.strip().lower() == "status":
            return value.strip()
    return None


def format_number(value: float) -> str:
    return f"{value:g}"
