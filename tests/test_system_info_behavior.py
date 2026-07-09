from __future__ import annotations

import pytest

from localai import system_info
from localai.ops import CommandResult


def test_collect_system_merges_all_probes(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(system_info, "_cpu_percent", lambda: 7)
    monkeypatch.setattr(system_info, "_disk_free_gb", lambda: 123.4)
    monkeypatch.setattr(
        system_info,
        "_memory_status",
        lambda: {"ramUsedGb": 10.1, "ramTotalGb": 31.7, "ramPercent": 32},
    )
    monkeypatch.setattr(
        system_info,
        "_battery_status",
        lambda: {"batteryPercent": 88, "onAc": True},
    )
    monkeypatch.setattr(
        system_info,
        "_gpu_status",
        lambda: {
            "gpuPercent": 3,
            "vramUsedGb": 1.2,
            "vramTotalGb": 12.0,
            "gpuTempC": 41,
        },
    )

    assert system_info.collect_system() == {
        "cpuPercent": 7,
        "ramUsedGb": 10.1,
        "ramTotalGb": 31.7,
        "ramPercent": 32,
        "diskFreeGb": 123.4,
        "batteryPercent": 88,
        "onAc": True,
        "gpuPercent": 3,
        "vramUsedGb": 1.2,
        "vramTotalGb": 12.0,
        "gpuTempC": 41,
    }


def test_collect_system_degrades_to_none_values(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(system_info, "_cpu_percent", lambda: None)
    monkeypatch.setattr(system_info, "_disk_free_gb", lambda: None)
    monkeypatch.setattr(system_info, "_memory_status", lambda: None)
    monkeypatch.setattr(system_info, "_battery_status", lambda: None)
    monkeypatch.setattr(system_info, "_gpu_status", lambda: None)

    payload = system_info.collect_system()

    assert set(payload.values()) == {None}
    assert "batteryPercent" in payload
    assert "vramTotalGb" in payload


def test_gpu_status_parses_nvidia_smi_csv(monkeypatch: pytest.MonkeyPatch) -> None:
    result = CommandResult(("nvidia-smi",), 0, "3, 1100, 12282, 47\n", "")
    monkeypatch.setattr(system_info, "run_command", lambda *a, **k: result)

    assert system_info._gpu_status() == {
        "gpuPercent": 3,
        "vramUsedGb": 1.1,
        "vramTotalGb": 12.0,
        "gpuTempC": 47,
    }


def test_gpu_status_is_none_when_probe_fails(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    result = CommandResult(("nvidia-smi",), 1, "", "Launch failed: not found\n")
    monkeypatch.setattr(system_info, "run_command", lambda *a, **k: result)

    assert system_info._gpu_status() is None


def test_cpu_percent_needs_two_samples(monkeypatch: pytest.MonkeyPatch) -> None:
    samples = iter([(100, 300, 200), (200, 500, 400)])
    monkeypatch.setattr(system_info, "_system_times", lambda: next(samples))
    monkeypatch.setattr(system_info, "_last_cpu_sample", None)

    assert system_info._cpu_percent() is None  # first poll has no delta yet
    # idle delta 100 of 400 total ticks -> 75% busy
    assert system_info._cpu_percent() == 75


def test_cpu_percent_is_none_without_the_probe(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(system_info, "_system_times", lambda: None)
    monkeypatch.setattr(system_info, "_last_cpu_sample", None)

    assert system_info._cpu_percent() is None
