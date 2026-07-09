"""Whole-machine telemetry for the dashboard System panel.

Windows-first and dependency-free on purpose: RAM/battery/CPU come from
kernel32 via ctypes (the codebase's established pattern - see model_scout's
memory probe), the GPU from nvidia-smi. Every probe degrades to None so the
panel renders on any box.
"""

from __future__ import annotations

import ctypes
import shutil
import sys
import threading
from typing import Any

from localai.ops import run_command
from localai.paths import REPO_ROOT


def collect_system() -> dict[str, Any]:
    """One poll of laptop-at-a-glance stats; missing probes report None."""
    info: dict[str, Any] = {
        "cpuPercent": _cpu_percent(),
        "ramUsedGb": None,
        "ramTotalGb": None,
        "ramPercent": None,
        "diskFreeGb": _disk_free_gb(),
        "batteryPercent": None,
        "onAc": None,
        "gpuPercent": None,
        "vramUsedGb": None,
        "vramTotalGb": None,
        "gpuTempC": None,
    }
    for probe in (_memory_status, _battery_status, _gpu_status):
        values = probe()
        if values:
            info.update(values)
    return info


def _disk_free_gb() -> float | None:
    try:
        free = shutil.disk_usage(str(REPO_ROOT.anchor or REPO_ROOT)).free
    except OSError:
        return None
    return round(free / 1024**3, 1)


class _MemoryStatusEx(ctypes.Structure):
    _fields_ = [
        ("dwLength", ctypes.c_ulong),
        ("dwMemoryLoad", ctypes.c_ulong),
        ("ullTotalPhys", ctypes.c_ulonglong),
        ("ullAvailPhys", ctypes.c_ulonglong),
        ("ullTotalPageFile", ctypes.c_ulonglong),
        ("ullAvailPageFile", ctypes.c_ulonglong),
        ("ullTotalVirtual", ctypes.c_ulonglong),
        ("ullAvailVirtual", ctypes.c_ulonglong),
        ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
    ]


def _memory_status() -> dict[str, Any] | None:
    status = _MemoryStatusEx()
    status.dwLength = ctypes.sizeof(_MemoryStatusEx)
    try:
        ok = ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status))
    except (AttributeError, OSError):
        return None
    if not ok:
        return None
    total = int(status.ullTotalPhys)
    avail = int(status.ullAvailPhys)
    return {
        "ramUsedGb": round((total - avail) / 1024**3, 1),
        "ramTotalGb": round(total / 1024**3, 1),
        "ramPercent": int(status.dwMemoryLoad),
    }


class _SystemPowerStatus(ctypes.Structure):
    _fields_ = [
        ("ACLineStatus", ctypes.c_ubyte),
        ("BatteryFlag", ctypes.c_ubyte),
        ("BatteryLifePercent", ctypes.c_ubyte),
        ("SystemStatusFlag", ctypes.c_ubyte),
        ("BatteryLifeTime", ctypes.c_uint32),
        ("BatteryFullLifeTime", ctypes.c_uint32),
    ]


def _battery_status() -> dict[str, Any] | None:
    status = _SystemPowerStatus()
    try:
        ok = ctypes.windll.kernel32.GetSystemPowerStatus(ctypes.byref(status))
    except (AttributeError, OSError):
        return None
    if not ok:
        return None
    values: dict[str, Any] = {}
    if status.BatteryLifePercent != 255:  # 255 = unknown / no battery
        values["batteryPercent"] = int(status.BatteryLifePercent)
    if status.ACLineStatus in (0, 1):  # 255 = unknown
        values["onAc"] = status.ACLineStatus == 1
    return values or None


def _gpu_status(*, timeout_sec: float = 5) -> dict[str, Any] | None:
    result = run_command(
        [
            "nvidia-smi",
            "--query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu",
            "--format=csv,noheader,nounits",
        ],
        cwd=REPO_ROOT,
        timeout_sec=timeout_sec,
    )
    if result.code != 0 or not result.text.strip():
        return None
    parts = [part.strip() for part in result.text.strip().splitlines()[0].split(",")]
    if len(parts) < 4:
        return None

    def num(raw: str) -> float | None:
        try:
            return float(raw)
        except ValueError:
            return None

    util, used, total, temp = (num(part) for part in parts[:4])
    values: dict[str, Any] = {}
    if util is not None:
        values["gpuPercent"] = round(util)
    if used is not None:
        values["vramUsedGb"] = round(used / 1024, 1)
    if total is not None:
        values["vramTotalGb"] = round(total / 1024, 1)
    if temp is not None:
        values["gpuTempC"] = round(temp)
    return values or None


# CPU% needs two GetSystemTimes samples; keep the previous one between polls.
# The dashboard polls every 15s, so each reading covers the last poll window.
_CPU_SAMPLE_LOCK = threading.Lock()
_last_cpu_sample: tuple[int, int, int] | None = None


def _system_times() -> tuple[int, int, int] | None:
    """(idle, kernel, user) 100ns tick totals; kernel time includes idle."""
    if sys.platform != "win32":
        return None

    class FileTime(ctypes.Structure):
        _fields_ = [
            ("dwLowDateTime", ctypes.c_uint32),
            ("dwHighDateTime", ctypes.c_uint32),
        ]

    idle, kernel, user = FileTime(), FileTime(), FileTime()
    try:
        ok = ctypes.windll.kernel32.GetSystemTimes(
            ctypes.byref(idle), ctypes.byref(kernel), ctypes.byref(user)
        )
    except (AttributeError, OSError):
        return None
    if not ok:
        return None

    def ticks(value: FileTime) -> int:
        return (int(value.dwHighDateTime) << 32) | int(value.dwLowDateTime)

    return ticks(idle), ticks(kernel), ticks(user)


def _cpu_percent() -> int | None:
    """Whole-machine CPU percent since the previous poll; None on first call."""
    global _last_cpu_sample
    sample = _system_times()
    if sample is None:
        return None
    with _CPU_SAMPLE_LOCK:
        previous, _last_cpu_sample = _last_cpu_sample, sample
    if previous is None:
        return None
    idle = sample[0] - previous[0]
    total = (sample[1] - previous[1]) + (sample[2] - previous[2])
    if total <= 0:
        return None
    return max(0, min(100, round((total - idle) * 100 / total)))
