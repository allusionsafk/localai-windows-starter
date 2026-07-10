"""Hardware -> capability tier for the Friend Bootstrapper installer.

Pure logic: given vetted hardware (VRAM/RAM/disk), pick the capability tier and
its context ceiling from ``installer/tiers.json`` -- the single source of truth
shared with the PowerShell vet phase. The VRAM-fit formula mirrors
``model_scout`` (weights + KV(ctx) + overhead); a drift test keeps tiers.json's
constants equal to the scout's, so the two sides never diverge.
"""

from __future__ import annotations

import json
import math
import shutil
from pathlib import Path
from typing import Any

from localai import model_scout
from localai.ops import run_command
from localai.paths import REPO_ROOT, repo_path

# Warn thresholds (informational; never block the install).
RAM_WARN_GB = 16  # Docker Desktop + WSL2 want 8+; below 16 the box feels tight.
DISK_WARN_GB = 40  # models are 4-20 GB each; below this the plan must shrink.


def tiers_path() -> Path:
    """Location of the single-source tier definitions."""
    return repo_path("installer", "tiers.json")


def load_tiers(path: Path | None = None) -> dict[str, Any]:
    """Read ``installer/tiers.json``."""
    target = path or tiers_path()
    data: dict[str, Any] = json.loads(target.read_text(encoding="utf-8"))
    return data


def _kv_per_1k(params_b: float, tiers: dict[str, Any]) -> float:
    """GB of f16 KV per 1k tokens for a model of ``params_b`` B, bucketed by
    total size (mirrors ``model_scout.kv_gb_per_1k``)."""
    buckets = sorted(
        (math.inf if key == "inf" else float(key), float(value))
        for key, value in tiers["kv_gb_per_1k"].items()
    )
    for ceiling, value in buckets:
        if params_b <= ceiling:
            return value
    return buckets[-1][1]


def fit_gb(
    params_b: float,
    *,
    ctx: int,
    tiers: dict[str, Any],
    kv_dtype: str | None = None,
    parallel: int = 1,
) -> float:
    """VRAM demand (GB) for a dense model: weights + KV(ctx) + overhead.

    ``kv_dtype`` defaults to the tiers' ``kv_dtype_default`` (q8_0 -- the host KV
    cache the installer sets). Rounding matches ``model_scout.estimate_kv_gb``.
    """
    dtype = kv_dtype or tiers.get("kv_dtype_default", "f16")
    factor = float(tiers["kv_dtype_factor"][dtype])
    weights = round(params_b * float(tiers["weights_gb_per_b"]), 1)
    kv = round(_kv_per_1k(params_b, tiers) * (ctx / 1024) * parallel * factor, 2)
    return round(weights + kv + float(tiers["overhead_gb"]), 2)


def classify_tier(
    vram_gb: float | None, *, tiers: dict[str, Any]
) -> dict[str, Any]:
    """Highest tier whose ``min_vram_gb`` the card meets. No GPU / 0 VRAM -> CPU.

    Boundaries are inclusive (a 16.0 GB card is S, not A) to honour the
    ``get_vram_gb`` 1-decimal rounding contract (audit finding 15).
    """
    usable = 0.0 if vram_gb is None else vram_gb
    eligible = [tier for tier in tiers["tiers"] if usable >= tier["min_vram_gb"]]
    return max(eligible, key=lambda tier: tier["min_vram_gb"])


# A non-empty video-controller name is NVIDIA (usable) if it carries one of these.
_NVIDIA_MARKERS = ("nvidia", "geforce", "rtx", "gtx", "quadro", "tesla")
# ...and is not a real accelerator the user could expect to use if it looks like a
# basic/virtual/remote display adapter.
_NON_ACCELERATOR_MARKERS = (
    "microsoft basic",
    "basic display",
    "basic render",
    "remote display",
    "virtual",
    "vmware",
    "citrix",
    "parsec",
)


def non_nvidia_gpu_note(gpu: str | None, vram_gb: float | None) -> str | None:
    """One honest line when the box has a real non-NVIDIA GPU but no usable NVIDIA
    VRAM (P1.6). Ollama on Windows is CUDA-only, so an AMD/Intel dGPU sits idle and
    the friend runs on CPU -- say so plainly instead of a generic 'no NVIDIA VRAM'
    that reads like a detection failure. ``None`` when there's no such GPU."""
    if vram_gb:  # usable NVIDIA VRAM -> normal GPU path, nothing to explain
        return None
    if not gpu:
        return None
    low = gpu.lower()
    if any(marker in low for marker in _NVIDIA_MARKERS):
        return None  # an NVIDIA card with no VRAM read is a driver issue, not this
    if any(marker in low for marker in _NON_ACCELERATOR_MARKERS):
        return None  # basic/virtual adapter, not a GPU the user expects to help
    return (
        f"{gpu} is not an NVIDIA GPU, which this stack requires — it will run on "
        "CPU only, which is much slower."
    )


def vet_capability(
    *,
    vram_gb: float | None,
    ram_gb: float | None,
    disk_free_gb: float | None,
    gpu: str | None,
    tiers: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Build the capability card: tier + context ceiling + honest warnings."""
    resolved = tiers or load_tiers()
    tier = classify_tier(vram_gb, tiers=resolved)
    warnings: list[str] = []
    if ram_gb is not None and ram_gb < RAM_WARN_GB:
        warnings.append(
            f"RAM {ram_gb:g} GB < {RAM_WARN_GB} GB: Docker Desktop + WSL2 want "
            "8+ GB, expect memory pressure"
        )
    if disk_free_gb is not None and disk_free_gb < DISK_WARN_GB:
        warnings.append(
            f"Disk {disk_free_gb:g} GB free < {DISK_WARN_GB} GB: models are "
            "4-20 GB each, the model plan will be trimmed"
        )
    if tier["id"] == "CPU":
        note = non_nvidia_gpu_note(gpu, vram_gb)
        warnings.append(
            note or tier.get("warn") or "CPU-only tier: slow, small models only"
        )
    return {
        "tier": tier["id"],
        "vram_gb": vram_gb,
        "ram_gb": ram_gb,
        "disk_free_gb": disk_free_gb,
        "gpu": gpu,
        "ctx": tier["ctx"],
        "warnings": warnings,
    }


def get_gpu_name(*, timeout_sec: int) -> str | None:
    """GPU name from nvidia-smi, or None (presence/name only, never VRAM math)."""
    result = run_command(
        ["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"],
        cwd=REPO_ROOT,
        timeout_sec=timeout_sec,
    )
    if result.code != 0 or not result.text.strip():
        return None
    return result.text.splitlines()[0].strip()


def _disk_free_gb() -> float | None:
    """Free disk on the checkout's drive, matching model_scout's rounding."""
    try:
        free = shutil.disk_usage(str(REPO_ROOT.anchor or REPO_ROOT)).free
    except OSError:
        return None
    return round(free / 1024**3, 1)


def _fmt(value: float | None) -> str:
    return "?" if value is None else f"{value:g}"


def collect_vet_report(
    *, json_output: bool = False, timeout_sec: int = 30
) -> tuple[int, list[str]]:
    """Probe hardware and report the capability card.

    ``--json`` emits exactly one JSON line for the PowerShell vet phase to parse
    and store in installer-state.json; the human form prints a readable card.
    """
    vram = model_scout.get_vram_gb(timeout_sec=timeout_sec)
    ram = model_scout.get_ram_gb(timeout_sec=timeout_sec)
    disk = _disk_free_gb()
    gpu = get_gpu_name(timeout_sec=timeout_sec)
    card = vet_capability(vram_gb=vram, ram_gb=ram, disk_free_gb=disk, gpu=gpu)

    if json_output:
        return 0, [json.dumps(card)]

    ram_s = _fmt(card["ram_gb"])
    disk_s = _fmt(card["disk_free_gb"])
    lines = [
        "==== localai capability vet ====",
        f"Tier {card['tier']}  (context ceiling {card['ctx']} tokens)",
        f"GPU:  {card['gpu'] or 'none detected'}  |  VRAM: {_fmt(card['vram_gb'])} GB",
        f"RAM:  {ram_s} GB  |  Free disk: {disk_s} GB",
    ]
    lines.extend(f"  ! {warning}" for warning in card["warnings"])
    return 0, lines
