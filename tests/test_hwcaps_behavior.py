from __future__ import annotations

import inspect
import json
from collections.abc import Sequence
from pathlib import Path

import pytest

from localai import hwcaps
from localai.ops import CommandResult

GIB = 1024**3
MIB = 1024**2


def _runner(
    *,
    stdout: str = "",
    stderr: str = "",
    code: int = 0,
) -> hwcaps.CommandRunner:
    def run(
        args: Sequence[str],
        *,
        cwd: Path | None = None,
        timeout_sec: float | None = None,
    ) -> CommandResult:
        del cwd, timeout_sec
        return CommandResult(tuple(args), code, stdout, stderr)

    return run


def _probe(
    *,
    system: str,
    machine: str,
    runner: hwcaps.CommandRunner | None = None,
    memory_bytes: int | None = 32 * GIB,
    cpu_name: str = "Test CPU",
    extra_accelerators: tuple[hwcaps.Accelerator, ...] = (),
) -> hwcaps.HardwareReport:
    return hwcaps.probe_hardware(
        timeout_sec=3,
        system=system,
        machine=machine,
        cpu_name=cpu_name,
        command_runner=runner or _runner(code=1, stderr="not found"),
        memory_probe=lambda: memory_bytes,
        extra_accelerators=extra_accelerators,
    )


def test_windows_nvidia_report_preserves_measured_vram_and_selected_cuda() -> None:
    report = _probe(
        system="Windows",
        machine="AMD64",
        runner=_runner(
            stdout="0, NVIDIA Test GPU A, 12282, 581.80\n"
        ),
        memory_bytes=32 * GIB,
        cpu_name="AMD Ryzen 9 7945HX",
    )

    assert report.operating_system == "windows"
    assert report.architecture == "x86_64"
    assert report.total_memory_bytes == 32 * GIB
    gpu = next(item for item in report.accelerators if item.vendor == "NVIDIA")
    assert gpu.kind is hwcaps.AcceleratorType.GPU
    assert gpu.device_name == "NVIDIA Test GPU A"
    assert gpu.dedicated_memory_bytes == 12282 * MIB
    assert gpu.driver_version == "581.80"
    assert gpu.evidence is hwcaps.Evidence.REPORTED
    assert gpu.runtimes[0].backend == "cuda"
    assert gpu.runtimes[0].status is hwcaps.RuntimeStatus.SELECTED
    assert report.selected_runtime is not None
    assert report.selected_runtime.backend == "cuda"


def test_nvidia_command_unavailable_selects_cpu_without_phantom_vram() -> None:
    report = _probe(
        system="Windows",
        machine="x86_64",
        runner=_runner(code=1, stderr="Launch failed: not found\n"),
    )

    assert all(item.vendor != "NVIDIA" for item in report.accelerators)
    assert report.selected_runtime is not None
    assert report.selected_runtime.backend == "cpu"
    assert report.total_dedicated_gpu_memory_bytes is None


def test_malformed_nvidia_output_fails_closed() -> None:
    report = _probe(
        system="Windows",
        machine="AMD64",
        runner=_runner(stdout="not,a,valid,row\n"),
    )

    assert all(item.vendor != "NVIDIA" for item in report.accelerators)
    assert any("malformed" in warning.lower() for warning in report.warnings)
    assert report.selected_runtime is not None
    assert report.selected_runtime.backend == "cpu"


def test_multi_gpu_nvidia_output_keeps_each_accelerator() -> None:
    report = _probe(
        system="Windows",
        machine="AMD64",
        runner=_runner(
            stdout=(
                "0, NVIDIA Test GPU A, 12282, 581.80\n"
                "1, NVIDIA RTX 3060, 6144, 581.80\n"
            )
        ),
    )

    nvidia = [item for item in report.accelerators if item.vendor == "NVIDIA"]
    assert [item.device_name for item in nvidia] == [
        "NVIDIA Test GPU A",
        "NVIDIA RTX 3060",
    ]
    assert [item.dedicated_memory_bytes for item in nvidia] == [
        12282 * MIB,
        6144 * MIB,
    ]


@pytest.mark.parametrize(
    ("system", "machine", "expected_os"),
    [
        ("Windows", "AMD64", "windows"),
        ("Linux", "x86_64", "linux"),
    ],
)
def test_cpu_only_reports_are_explicit(
    system: str, machine: str, expected_os: str
) -> None:
    report = _probe(system=system, machine=machine)

    assert report.operating_system == expected_os
    cpu = next(
        item
        for item in report.accelerators
        if item.kind is hwcaps.AcceleratorType.CPU
    )
    assert cpu.device_name == "Test CPU"
    assert cpu.runtimes[0].backend == "cpu"
    assert cpu.runtimes[0].status is hwcaps.RuntimeStatus.SELECTED


def test_macos_apple_silicon_reports_unified_memory_and_experimental_metal() -> None:
    report = _probe(
        system="Darwin",
        machine="arm64",
        memory_bytes=24 * GIB,
        cpu_name="Apple M4 Pro",
    )

    apple = next(item for item in report.accelerators if item.vendor == "Apple")
    assert apple.device_name == "Apple M4 Pro"
    assert apple.unified_memory_bytes == 24 * GIB
    assert apple.dedicated_memory_bytes is None
    assert apple.runtimes[0].backend == "metal"
    assert apple.runtimes[0].status is hwcaps.RuntimeStatus.EXPERIMENTAL
    assert report.selected_runtime is not None
    assert report.selected_runtime.backend == "cpu"


def test_unknown_architecture_is_explicit_and_does_not_crash() -> None:
    report = _probe(system="Plan9", machine="mips64")

    assert report.operating_system == "unknown"
    assert report.architecture == "unknown"
    assert any("architecture" in warning.lower() for warning in report.warnings)


def test_failed_ram_probe_is_unknown_not_zero() -> None:
    report = _probe(system="Linux", machine="x86_64", memory_bytes=None)

    assert report.total_memory_bytes is None
    assert report.memory_evidence is hwcaps.Evidence.UNKNOWN
    assert any("memory" in warning.lower() for warning in report.warnings)


def test_detected_npu_stays_unsupported_and_unselected() -> None:
    npu = hwcaps.Accelerator(
        kind=hwcaps.AcceleratorType.NPU,
        vendor="Qualcomm",
        device_name="Qualcomm Hexagon NPU",
        evidence=hwcaps.Evidence.REPORTED,
        runtimes=(
            hwcaps.RuntimeCapability(
                name="Windows ML QNN",
                backend="qnn",
                status=hwcaps.RuntimeStatus.UNSUPPORTED,
                evidence=hwcaps.Evidence.INFERRED,
            ),
        ),
    )

    report = _probe(
        system="Windows",
        machine="ARM64",
        extra_accelerators=(npu,),
    )

    detected = next(
        item
        for item in report.accelerators
        if item.kind is hwcaps.AcceleratorType.NPU
    )
    assert detected.runtimes[0].status is hwcaps.RuntimeStatus.UNSUPPORTED
    assert report.selected_runtime is not None
    assert report.selected_runtime.backend == "cpu"
    assert any("unsupported" in warning.lower() for warning in report.warnings)


def test_linux_memory_uses_sysconf_without_a_dependency() -> None:
    values = {"SC_PHYS_PAGES": 8_388_608, "SC_PAGE_SIZE": 4096}

    reading = hwcaps.probe_total_memory(
        system="Linux",
        command_runner=_runner(),
        timeout_sec=2,
        sysconf=lambda key: values[key],
    )

    assert reading.total_bytes == 32 * GIB
    assert reading.evidence is hwcaps.Evidence.MEASURED
    assert reading.source == "os.sysconf"


def test_macos_memory_uses_bounded_sysctl() -> None:
    reading = hwcaps.probe_total_memory(
        system="Darwin",
        command_runner=_runner(stdout=f"{24 * GIB}\n"),
        timeout_sec=2,
    )

    assert reading.total_bytes == 24 * GIB
    assert reading.source == "sysctl:hw.memsize"


def test_json_serialization_is_bounded_and_scrubs_private_paths() -> None:
    report = _probe(
        system="Windows",
        machine="AMD64",
        cpu_name=r"C:\Users\example\private-cpu-name",
        runner=_runner(
            stdout=(
                "0, NVIDIA Device C:\\Users\\example\\private-name, "
                "12282, 581.80\n"
            )
        ),
    )

    text = report.to_json()
    payload = json.loads(text)

    assert payload["operating_system"] == "windows"
    assert payload["selected_runtime"]["backend"] == "cuda"
    assert r"C:\Users" not in text
    assert "/home/" not in text
    assert len(text.encode("utf-8")) <= hwcaps.MAX_JSON_BYTES


def test_human_report_distinguishes_runtime_statuses() -> None:
    report = _probe(
        system="Windows",
        machine="AMD64",
        runner=_runner(
            stdout="0, NVIDIA Test GPU A, 12282, 581.80\n"
        ),
    )

    text = "\n".join(hwcaps.format_hardware_report(report))

    assert "OS: windows / x86_64" in text
    assert "Memory: 32.0 GB (measured)" in text
    assert "NVIDIA Test GPU A" in text
    assert "Selected runtime: Ollama CUDA [cuda]" in text
    assert "Available runtime: Ollama CPU [cpu]" in text
    assert "Experimental runtime: none" in text
    assert "Unsupported NPU: none" in text


def test_hardware_cli_is_registered_with_json_and_timeout_options() -> None:
    from localai import cli

    command = next(
        info.callback
        for info in cli.app.registered_commands
        if info.callback and info.callback.__name__ == "hardware"
    )
    signature = inspect.signature(command)

    assert "json_output" in signature.parameters
    assert "timeout_sec" in signature.parameters


def test_hardware_cli_emits_one_bounded_json_document(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    from localai import cli

    report = _probe(
        system="Windows",
        machine="AMD64",
        runner=_runner(
            stdout="0, NVIDIA Test GPU A, 12282, 581.80\n"
        ),
    )
    monkeypatch.setattr(cli, "probe_hardware", lambda **kwargs: report)

    cli.hardware(json_output=True, timeout_sec=7)
    lines = capsys.readouterr().out.splitlines()

    assert len(lines) == 1
    assert json.loads(lines[0])["selected_runtime"]["backend"] == "cuda"
