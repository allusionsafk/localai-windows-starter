from __future__ import annotations

import json

import pytest

from localai import installer_vet, model_scout


def test_classify_tier_boundaries_are_inclusive() -> None:
    tiers = installer_vet.load_tiers()
    # Exact min_vram_gb lands in the tier it names (finding 15: rounding contract
    # means a 16376 MiB card reports 16.0 and must resolve to S, not A).
    assert installer_vet.classify_tier(16.0, tiers=tiers)["id"] == "S"
    assert installer_vet.classify_tier(12.0, tiers=tiers)["id"] == "A"
    assert installer_vet.classify_tier(8.0, tiers=tiers)["id"] == "B"
    assert installer_vet.classify_tier(4.0, tiers=tiers)["id"] == "C"
    assert installer_vet.classify_tier(0.0, tiers=tiers)["id"] == "CPU"


def test_classify_tier_below_boundary_drops_one_tier() -> None:
    tiers = installer_vet.load_tiers()
    assert installer_vet.classify_tier(15.9, tiers=tiers)["id"] == "A"
    assert installer_vet.classify_tier(11.9, tiers=tiers)["id"] == "B"
    assert installer_vet.classify_tier(7.9, tiers=tiers)["id"] == "C"
    assert installer_vet.classify_tier(3.9, tiers=tiers)["id"] == "CPU"


def test_no_gpu_falls_back_to_cpu_tier() -> None:
    tiers = installer_vet.load_tiers()
    # nvidia-smi absent -> vram is None (NOT a false 12; audit finding 4).
    assert installer_vet.classify_tier(None, tiers=tiers)["id"] == "CPU"


def test_every_tier_fits_its_own_min_vram_at_q8_0() -> None:
    """Audit finding 5: each tier's ceiling model must pass the VRAM gate at its
    own min_vram_gb, given the host q8_0 KV cache the installer sets."""
    tiers = installer_vet.load_tiers()
    for tier in tiers["tiers"]:
        if tier["id"] == "CPU":
            continue  # no VRAM gate
        fit = installer_vet.fit_gb(
            tier["max_dense_b"], ctx=tier["ctx"], tiers=tiers, kv_dtype="q8_0"
        )
        assert fit <= tier["min_vram_gb"], (
            f"tier {tier['id']}: {tier['max_dense_b']}B@{tier['ctx']} "
            f"= {fit} GB > {tier['min_vram_gb']} GB gate"
        )


def test_reference_box_9b_at_32k_needs_q8_0() -> None:
    """The daily driver (9B@32k, tier A) fits 12 GB only with q8_0 KV; at f16 it
    spills. This pins why the installer must set OLLAMA_KV_CACHE_TYPE=q8_0."""
    tiers = installer_vet.load_tiers()
    assert installer_vet.fit_gb(9, ctx=32768, tiers=tiers, kv_dtype="q8_0") <= 12
    assert installer_vet.fit_gb(9, ctx=32768, tiers=tiers, kv_dtype="f16") > 12


def test_tiers_json_constants_mirror_model_scout() -> None:
    """tiers.json is the PowerShell-side mirror; its constants must equal the
    authoritative model_scout values or the two sides drift (plan: single source,
    never duplicate the numbers)."""
    tiers = installer_vet.load_tiers()
    assert tiers["weights_gb_per_b"] == model_scout.WEIGHTS_GB_PER_B
    assert tiers["overhead_gb"] == model_scout.VRAM_OVERHEAD_GB
    assert tiers["kv_dtype_factor"]["q8_0"] == model_scout.KV_DTYPE_FACTORS["q8_0"]
    assert tiers["kv_dtype_factor"]["f16"] == model_scout.KV_DTYPE_FACTORS["f16"]
    # kv_gb_per_1k buckets must match the scout's bucket table exactly.
    for ceiling, value in model_scout.KV_GB_PER_1K_BUCKETS:
        assert tiers["kv_gb_per_1k"][str(int(ceiling))] == value


def test_vet_capability_reports_tier_and_hardware() -> None:
    card = installer_vet.vet_capability(
        vram_gb=12.0, ram_gb=32.0, disk_free_gb=180.0, gpu="Test GPU"
    )
    assert card["tier"] == "A"
    assert card["vram_gb"] == 12.0
    assert card["gpu"] == "Test GPU"
    assert card["warnings"] == []


def test_vet_capability_warns_on_low_ram_and_disk() -> None:
    card = installer_vet.vet_capability(
        vram_gb=8.0, ram_gb=12.0, disk_free_gb=25.0, gpu="RTX 3060"
    )
    joined = " ".join(card["warnings"]).lower()
    assert "ram" in joined  # < 16 GB warn (Docker Desktop + WSL2 want 8+)
    assert "disk" in joined  # < 40 GB free warn (models are 4-20 GB each)


def test_vet_capability_json_keys_are_stable_for_powershell() -> None:
    card = installer_vet.vet_capability(
        vram_gb=12.0, ram_gb=32.0, disk_free_gb=180.0, gpu="Test GPU"
    )
    assert set(card) == {
        "tier",
        "vram_gb",
        "ram_gb",
        "disk_free_gb",
        "gpu",
        "ctx",
        "warnings",
    }


# ------------------------------------------------- localai vet CLI report


def _patch_probes(
    monkeypatch: pytest.MonkeyPatch,
    *,
    vram: float | None,
    ram: float | None,
    disk: float | None,
    gpu: str | None,
) -> None:
    monkeypatch.setattr(model_scout, "get_vram_gb", lambda *, timeout_sec: vram)
    monkeypatch.setattr(model_scout, "get_ram_gb", lambda *, timeout_sec: ram)
    monkeypatch.setattr(installer_vet, "_disk_free_gb", lambda: disk)
    monkeypatch.setattr(installer_vet, "get_gpu_name", lambda *, timeout_sec: gpu)


def test_collect_vet_report_json_is_one_parseable_line(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _patch_probes(monkeypatch, vram=12.0, ram=32.0, disk=180.0, gpu="Test GPU")

    code, lines = installer_vet.collect_vet_report(json_output=True)

    assert code == 0
    assert len(lines) == 1  # PowerShell parses exactly one JSON line
    card = json.loads(lines[0])
    assert card["tier"] == "A"
    assert card["vram_gb"] == 12.0


def test_collect_vet_report_human_names_the_tier(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _patch_probes(monkeypatch, vram=12.0, ram=32.0, disk=180.0, gpu="Test GPU")

    code, lines = installer_vet.collect_vet_report(json_output=False)

    assert code == 0
    blob = "\n".join(lines)
    assert "A" in blob
    assert "Test GPU" in blob


def test_collect_vet_report_surfaces_no_gpu_as_cpu_tier(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # nvidia-smi absent: vram None -> CPU tier, warning surfaced (audit finding 4).
    _patch_probes(monkeypatch, vram=None, ram=32.0, disk=180.0, gpu=None)

    code, lines = installer_vet.collect_vet_report(json_output=True)

    card = json.loads(lines[0])
    assert card["tier"] == "CPU"
    assert card["warnings"]  # CPU-only warning present


def test_cli_vet_command_registered_with_json_flag() -> None:
    import inspect

    from localai import cli

    vet = next(
        info.callback
        for info in cli.app.registered_commands
        if info.callback and info.callback.__name__ == "vet"
    )
    assert "json_output" in inspect.signature(vet).parameters
