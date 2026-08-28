"""Portable, fail-closed hardware capability reporting.

This module collects facts. Product policy stays explicit in runtime statuses,
and model-fit policy remains in :mod:`localai.model_scout`.
"""

from __future__ import annotations

import csv
import ctypes
import io
import json
import math
import os
import platform
import re
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from typing import Any, Protocol

from localai.ops import CommandResult, run_command
from localai.paths import REPO_ROOT

MAX_ACCELERATORS = 16
MAX_RUNTIMES_PER_ACCELERATOR = 8
MAX_WARNINGS = 32
MAX_PROVENANCE = 32
MAX_TEXT_CHARS = 160
MAX_JSON_BYTES = 128 * 1024

_GIB = 1024**3
_MIB = 1024**2
_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]+")
_PRIVATE_PATH_RE = re.compile(
    r"(?:[A-Za-z]:[\\/]|/(?:Users|home|private|tmp|var/tmp)/)",
    re.IGNORECASE,
)


class Evidence(StrEnum):
    """How a capability fact was obtained."""

    MEASURED = "measured"
    REPORTED = "reported"
    INFERRED = "inferred"
    UNKNOWN = "unknown"


class RuntimeStatus(StrEnum):
    """Product relationship to a detected runtime possibility."""

    SELECTED = "selected"
    AVAILABLE = "available"
    EXPERIMENTAL = "experimental"
    UNSUPPORTED = "unsupported"
    RESEARCH = "research"
    UNAVAILABLE = "unavailable"


class AcceleratorType(StrEnum):
    CPU = "cpu"
    GPU = "gpu"
    NPU = "npu"
    UNKNOWN = "unknown"


class CommandRunner(Protocol):
    """Shape accepted by bounded provider probes."""

    def __call__(
        self,
        args: Sequence[str],
        *,
        cwd: Path | None = None,
        timeout_sec: float | None = None,
    ) -> CommandResult: ...


@dataclass(frozen=True)
class RuntimeCapability:
    name: str
    backend: str
    status: RuntimeStatus
    evidence: Evidence
    version: str | None = None

    def to_dict(self) -> dict[str, str | None]:
        return {
            "name": _safe_text(self.name),
            "backend": _safe_token(self.backend),
            "status": self.status.value,
            "evidence": self.evidence.value,
            "version": _safe_optional_text(self.version),
        }


@dataclass(frozen=True)
class Accelerator:
    kind: AcceleratorType
    vendor: str
    device_name: str
    evidence: Evidence
    dedicated_memory_bytes: int | None = None
    shared_memory_bytes: int | None = None
    unified_memory_bytes: int | None = None
    driver_version: str | None = None
    runtimes: tuple[RuntimeCapability, ...] = ()

    def to_dict(self) -> dict[str, Any]:
        runtimes = self.runtimes[:MAX_RUNTIMES_PER_ACCELERATOR]
        return {
            "type": self.kind.value,
            "vendor": _safe_text(self.vendor),
            "device_name": _safe_text(self.device_name),
            "dedicated_memory_bytes": _valid_memory(self.dedicated_memory_bytes),
            "dedicated_memory_gb": _memory_gb(self.dedicated_memory_bytes),
            "shared_memory_bytes": _valid_memory(self.shared_memory_bytes),
            "shared_memory_gb": _memory_gb(self.shared_memory_bytes),
            "unified_memory_bytes": _valid_memory(self.unified_memory_bytes),
            "unified_memory_gb": _memory_gb(self.unified_memory_bytes),
            "driver_version": _safe_optional_text(self.driver_version),
            "evidence": self.evidence.value,
            "runtimes": [runtime.to_dict() for runtime in runtimes],
        }


@dataclass(frozen=True)
class MemoryReading:
    total_bytes: int | None
    evidence: Evidence
    source: str


@dataclass(frozen=True)
class HardwareReport:
    operating_system: str
    architecture: str
    cpu_identity: str | None
    total_memory_bytes: int | None
    memory_evidence: Evidence
    accelerators: tuple[Accelerator, ...]
    warnings: tuple[str, ...]
    provenance: tuple[str, ...]

    @property
    def runtimes(self) -> tuple[RuntimeCapability, ...]:
        return tuple(
            runtime
            for accelerator in self.accelerators
            for runtime in accelerator.runtimes[:MAX_RUNTIMES_PER_ACCELERATOR]
        )

    @property
    def selected_runtime(self) -> RuntimeCapability | None:
        return next(
            (
                runtime
                for runtime in self.runtimes
                if runtime.status is RuntimeStatus.SELECTED
            ),
            None,
        )

    @property
    def total_dedicated_gpu_memory_bytes(self) -> int | None:
        values = [
            accelerator.dedicated_memory_bytes
            for accelerator in self.accelerators
            if accelerator.kind is AcceleratorType.GPU
            and accelerator.dedicated_memory_bytes is not None
        ]
        return sum(values) if values else None

    def to_dict(self) -> dict[str, Any]:
        accelerators = self.accelerators[:MAX_ACCELERATORS]
        runtimes = self.runtimes
        by_status = {
            status.value: [
                runtime.to_dict()
                for runtime in runtimes
                if runtime.status is status
            ][:MAX_ACCELERATORS]
            for status in RuntimeStatus
        }
        selected = self.selected_runtime
        return {
            "schema_version": 1,
            "operating_system": _safe_token(self.operating_system),
            "architecture": _safe_token(self.architecture),
            "cpu_identity": _safe_optional_text(self.cpu_identity),
            "total_memory_bytes": _valid_memory(self.total_memory_bytes),
            "total_memory_gb": _memory_gb(self.total_memory_bytes),
            "memory_evidence": self.memory_evidence.value,
            "accelerators": [item.to_dict() for item in accelerators],
            "detected_backends": sorted(
                {_safe_token(runtime.backend) for runtime in runtimes}
            ),
            "selected_runtime": selected.to_dict() if selected else None,
            "runtimes_by_status": by_status,
            "warnings": [
                _safe_text(item) for item in self.warnings[:MAX_WARNINGS]
            ],
            "raw_probe_provenance": [
                _safe_text(item) for item in self.provenance[:MAX_PROVENANCE]
            ],
        }

    def to_json(self, *, indent: int | None = None) -> str:
        text = json.dumps(
            self.to_dict(),
            ensure_ascii=True,
            indent=indent,
            sort_keys=True,
        )
        if len(text.encode("utf-8")) > MAX_JSON_BYTES:
            msg = "hardware report exceeded its serialization bound"
            raise ValueError(msg)
        return text


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


def _safe_text(value: object, *, fallback: str = "unknown") -> str:
    text = _CONTROL_RE.sub(" ", str(value)).strip()
    text = " ".join(text.split())
    if not text:
        return fallback
    if _PRIVATE_PATH_RE.search(text):
        return "[redacted-path]"
    return text[:MAX_TEXT_CHARS]


def _safe_optional_text(value: object | None) -> str | None:
    if value is None:
        return None
    return _safe_text(value)


def _safe_token(value: object) -> str:
    text = _safe_text(value).lower()
    token = re.sub(r"[^a-z0-9_.+-]+", "-", text).strip("-")
    return token[:64] or "unknown"


def _valid_memory(value: int | None) -> int | None:
    if value is None or value <= 0:
        return None
    return int(value)


def _memory_gb(value: int | None) -> float | None:
    valid = _valid_memory(value)
    return None if valid is None else round(valid / _GIB, 1)


def normalize_operating_system(value: str) -> str:
    normalized = value.strip().lower()
    return {
        "windows": "windows",
        "linux": "linux",
        "darwin": "macos",
        "macos": "macos",
    }.get(normalized, "unknown")


def normalize_architecture(value: str) -> str:
    normalized = value.strip().lower()
    if normalized in {"amd64", "x86_64"}:
        return "x86_64"
    if normalized in {"arm64", "aarch64"}:
        return "arm64"
    if normalized in {"x86", "i386", "i686"}:
        return "x86"
    if normalized in {"arm", "armv7l", "armv8l"}:
        return "arm32"
    return "unknown"


def _windows_total_memory() -> MemoryReading:
    status = _MemoryStatusEx()
    status.dwLength = ctypes.sizeof(_MemoryStatusEx)
    windll = getattr(ctypes, "windll", None)
    if windll is None:
        return MemoryReading(None, Evidence.UNKNOWN, "ctypes:GlobalMemoryStatusEx")
    try:
        ok = windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status))
    except OSError:
        return MemoryReading(None, Evidence.UNKNOWN, "ctypes:GlobalMemoryStatusEx")
    total = int(status.ullTotalPhys) if ok else 0
    return MemoryReading(
        total if total > 0 else None,
        Evidence.MEASURED if total > 0 else Evidence.UNKNOWN,
        "ctypes:GlobalMemoryStatusEx",
    )


def probe_total_memory(
    *,
    system: str,
    command_runner: CommandRunner = run_command,
    timeout_sec: float = 5,
    sysconf: Callable[[str], int] | None = None,
) -> MemoryReading:
    """Read total physical memory through a built-in, platform-stable API."""

    normalized = normalize_operating_system(system)
    if normalized == "windows":
        return _windows_total_memory()
    if normalized == "linux":
        resolved_sysconf = sysconf or getattr(os, "sysconf", None)
        if resolved_sysconf is None:
            return MemoryReading(None, Evidence.UNKNOWN, "os.sysconf")
        try:
            pages = int(resolved_sysconf("SC_PHYS_PAGES"))
            page_size = int(resolved_sysconf("SC_PAGE_SIZE"))
        except (KeyError, OSError, TypeError, ValueError):
            return MemoryReading(None, Evidence.UNKNOWN, "os.sysconf")
        total = pages * page_size
        if pages <= 0 or page_size <= 0 or total <= 0:
            return MemoryReading(None, Evidence.UNKNOWN, "os.sysconf")
        return MemoryReading(total, Evidence.MEASURED, "os.sysconf")
    if normalized == "macos":
        result = command_runner(
            ["sysctl", "-n", "hw.memsize"],
            cwd=None,
            timeout_sec=timeout_sec,
        )
        if result.code == 0:
            try:
                total = int(result.stdout.strip())
            except ValueError:
                total = 0
            if total > 0:
                return MemoryReading(
                    total,
                    Evidence.REPORTED,
                    "sysctl:hw.memsize",
                )
        return MemoryReading(None, Evidence.UNKNOWN, "sysctl:hw.memsize")
    return MemoryReading(None, Evidence.UNKNOWN, "unsupported-os")


def _nvidia_runtime_status(
    *, operating_system: str, architecture: str
) -> RuntimeStatus:
    if operating_system == "windows" and architecture == "x86_64":
        return RuntimeStatus.SELECTED
    if operating_system == "windows":
        return RuntimeStatus.UNSUPPORTED
    return RuntimeStatus.RESEARCH


def _probe_nvidia(
    *,
    operating_system: str,
    architecture: str,
    command_runner: CommandRunner,
    timeout_sec: float,
) -> tuple[list[Accelerator], list[str], list[str]]:
    if operating_system not in {"windows", "linux"}:
        return [], [], []
    result = command_runner(
        [
            "nvidia-smi",
            "--query-gpu=index,name,memory.total,driver_version",
            "--format=csv,noheader,nounits",
        ],
        cwd=REPO_ROOT,
        timeout_sec=timeout_sec,
    )
    provenance = ["nvidia-smi:csv-query"]
    if result.code != 0 or not result.stdout.strip():
        return [], [], provenance

    accelerators: list[Accelerator] = []
    malformed = 0
    reader = csv.reader(io.StringIO(result.stdout))
    for row in reader:
        if len(accelerators) >= MAX_ACCELERATORS:
            break
        if len(row) != 4:
            malformed += 1
            continue
        index_text, name_text, memory_text, driver_text = (
            item.strip() for item in row
        )
        try:
            index = int(index_text)
            memory_mib = float(memory_text)
        except ValueError:
            malformed += 1
            continue
        if (
            index < 0
            or not math.isfinite(memory_mib)
            or memory_mib <= 0
            or memory_mib > (1024**4 / _MIB)
        ):
            malformed += 1
            continue
        status = _nvidia_runtime_status(
            operating_system=operating_system,
            architecture=architecture,
        )
        accelerators.append(
            Accelerator(
                kind=AcceleratorType.GPU,
                vendor="NVIDIA",
                device_name=_safe_text(name_text, fallback=f"NVIDIA GPU {index}"),
                dedicated_memory_bytes=round(memory_mib * _MIB),
                driver_version=_safe_text(driver_text),
                evidence=Evidence.REPORTED,
                runtimes=(
                    RuntimeCapability(
                        name="Ollama CUDA",
                        backend="cuda",
                        status=status,
                        evidence=Evidence.REPORTED,
                    ),
                ),
            )
        )

    warnings: list[str] = []
    if malformed:
        warnings.append(
            f"NVIDIA probe returned {malformed} malformed row(s); "
            "those accelerators were ignored."
        )
    if not accelerators and malformed:
        warnings.append(
            "No valid NVIDIA memory report was available; CPU fallback selected."
        )
    return accelerators, warnings, provenance


def _cpu_accelerator(cpu_identity: str, *, selected: bool) -> Accelerator:
    return Accelerator(
        kind=AcceleratorType.CPU,
        vendor="generic",
        device_name=cpu_identity,
        evidence=Evidence.REPORTED
        if cpu_identity != "unknown CPU"
        else Evidence.UNKNOWN,
        shared_memory_bytes=None,
        runtimes=(
            RuntimeCapability(
                name="Ollama CPU",
                backend="cpu",
                status=(
                    RuntimeStatus.SELECTED
                    if selected
                    else RuntimeStatus.AVAILABLE
                ),
                evidence=Evidence.INFERRED,
            ),
        ),
    )


def _apple_accelerator(
    *, cpu_identity: str, total_memory_bytes: int | None
) -> Accelerator:
    name = cpu_identity if cpu_identity != "unknown CPU" else "Apple Silicon GPU"
    return Accelerator(
        kind=AcceleratorType.GPU,
        vendor="Apple",
        device_name=name,
        unified_memory_bytes=total_memory_bytes,
        evidence=Evidence.INFERRED,
        runtimes=(
            RuntimeCapability(
                name="Ollama Metal",
                backend="metal",
                status=RuntimeStatus.EXPERIMENTAL,
                evidence=Evidence.INFERRED,
            ),
        ),
    )


def _default_cpu_identity() -> str:
    candidates = (platform.processor(), platform.uname().processor)
    return next(
        (_safe_text(item) for item in candidates if item and item.strip()),
        "unknown CPU",
    )


def probe_hardware(
    *,
    timeout_sec: float = 5,
    system: str | None = None,
    machine: str | None = None,
    cpu_name: str | None = None,
    command_runner: CommandRunner = run_command,
    memory_probe: Callable[[], int | None] | None = None,
    extra_accelerators: Sequence[Accelerator] = (),
) -> HardwareReport:
    """Build a bounded hardware report without changing system state."""

    raw_system = system if system is not None else platform.system()
    raw_machine = machine if machine is not None else platform.machine()
    operating_system = normalize_operating_system(raw_system)
    architecture = normalize_architecture(raw_machine)
    cpu_identity = _safe_text(
        cpu_name if cpu_name is not None else _default_cpu_identity(),
        fallback="unknown CPU",
    )

    warnings: list[str] = []
    provenance = ["platform.system", "platform.machine", "platform.processor"]
    if operating_system == "unknown":
        warnings.append(f"Unsupported operating system reported: {raw_system}.")
    if architecture == "unknown":
        warnings.append(f"Unrecognized architecture reported: {raw_machine}.")

    if memory_probe is None:
        memory = probe_total_memory(
            system=raw_system,
            command_runner=command_runner,
            timeout_sec=timeout_sec,
        )
    else:
        try:
            injected_total = memory_probe()
        except (OSError, TypeError, ValueError):
            injected_total = None
        total = _valid_memory(injected_total)
        memory = MemoryReading(
            total,
            Evidence.MEASURED if total is not None else Evidence.UNKNOWN,
            "memory-provider",
        )
    provenance.append(memory.source)
    if memory.total_bytes is None:
        warnings.append("Total physical memory is unknown.")

    detected, provider_warnings, provider_provenance = _probe_nvidia(
        operating_system=operating_system,
        architecture=architecture,
        command_runner=command_runner,
        timeout_sec=timeout_sec,
    )
    warnings.extend(provider_warnings)
    provenance.extend(provider_provenance)

    extras = list(extra_accelerators[:MAX_ACCELERATORS])
    accelerators = [*detected, *extras]
    if operating_system == "macos" and architecture == "arm64":
        accelerators.append(
            _apple_accelerator(
                cpu_identity=cpu_identity,
                total_memory_bytes=memory.total_bytes,
            )
        )
        provenance.append("platform:apple-silicon")

    selected_accelerator = any(
        runtime.status is RuntimeStatus.SELECTED
        for accelerator in accelerators
        for runtime in accelerator.runtimes
    )
    accelerators.append(
        _cpu_accelerator(cpu_identity, selected=not selected_accelerator)
    )

    if operating_system == "windows" and architecture == "arm64":
        warnings.append(
            "Ollama acceleration on Windows ARM64 is unsupported; "
            "CPU fallback selected."
        )
    if any(
        accelerator.kind is AcceleratorType.NPU
        and any(
            runtime.status is RuntimeStatus.UNSUPPORTED
            for runtime in accelerator.runtimes
        )
        for accelerator in extras
    ):
        warnings.append(
            "An NPU was detected, but its runtime is unsupported by AFK LocalAI."
        )

    return HardwareReport(
        operating_system=operating_system,
        architecture=architecture,
        cpu_identity=cpu_identity,
        total_memory_bytes=memory.total_bytes,
        memory_evidence=memory.evidence,
        accelerators=tuple(accelerators[:MAX_ACCELERATORS]),
        warnings=tuple(warnings[:MAX_WARNINGS]),
        provenance=tuple(dict.fromkeys(provenance))[:MAX_PROVENANCE],
    )


def _runtime_label(runtime: RuntimeCapability) -> str:
    evidence = runtime.evidence.value
    return (
        f"{_safe_text(runtime.name)} [{_safe_token(runtime.backend)}] "
        f"({evidence})"
    )


def _runtime_line(
    report: HardwareReport,
    *,
    label: str,
    status: RuntimeStatus,
) -> str:
    matches = [
        _runtime_label(runtime)
        for runtime in report.runtimes
        if runtime.status is status
    ]
    return f"{label}: {', '.join(dict.fromkeys(matches)) if matches else 'none'}"


def format_hardware_report(report: HardwareReport) -> list[str]:
    """Render a bounded, factual human-readable capability card."""

    memory = _memory_gb(report.total_memory_bytes)
    memory_text = (
        "unknown"
        if memory is None
        else f"{memory:.1f} GB ({report.memory_evidence.value})"
    )
    lines = [
        "==== localai hardware ====",
        f"OS: {_safe_token(report.operating_system)} / "
        f"{_safe_token(report.architecture)}",
        f"CPU: {_safe_optional_text(report.cpu_identity) or 'unknown'}",
        f"Memory: {memory_text}",
        "Detected hardware:",
    ]
    for accelerator in report.accelerators[:MAX_ACCELERATORS]:
        vendor = _safe_text(accelerator.vendor)
        device_name = _safe_text(accelerator.device_name)
        if (
            vendor.lower() in {"generic", "unknown"}
            or device_name.lower().startswith(vendor.lower())
        ):
            hardware_name = device_name
        else:
            hardware_name = f"{vendor} {device_name}"
        memory_parts: list[str] = []
        dedicated = _memory_gb(accelerator.dedicated_memory_bytes)
        shared = _memory_gb(accelerator.shared_memory_bytes)
        unified = _memory_gb(accelerator.unified_memory_bytes)
        if dedicated is not None:
            memory_parts.append(f"{dedicated:.1f} GB dedicated")
        if shared is not None:
            memory_parts.append(f"{shared:.1f} GB shared")
        if unified is not None:
            memory_parts.append(f"{unified:.1f} GB unified")
        suffix = f" | {', '.join(memory_parts)}" if memory_parts else ""
        lines.append(
            f"  - {accelerator.kind.value}: "
            f"{hardware_name}{suffix} "
            f"({accelerator.evidence.value})"
        )

    lines.extend(
        [
            _runtime_line(
                report,
                label="Selected runtime",
                status=RuntimeStatus.SELECTED,
            ),
            _runtime_line(
                report,
                label="Available runtime",
                status=RuntimeStatus.AVAILABLE,
            ),
            _runtime_line(
                report,
                label="Experimental runtime",
                status=RuntimeStatus.EXPERIMENTAL,
            ),
        ]
    )
    unsupported_npus = [
        _safe_text(accelerator.device_name)
        for accelerator in report.accelerators
        if accelerator.kind is AcceleratorType.NPU
        and any(
            runtime.status is RuntimeStatus.UNSUPPORTED
            for runtime in accelerator.runtimes
        )
    ]
    lines.append(
        "Unsupported NPU: "
        + (", ".join(unsupported_npus) if unsupported_npus else "none")
    )
    if report.warnings:
        lines.append("Warnings:")
        lines.extend(
            f"  ! {_safe_text(warning)}"
            for warning in report.warnings[:MAX_WARNINGS]
        )
    else:
        lines.append("Warnings: none")
    return lines
