from __future__ import annotations

from pathlib import Path

import pytest

from localai import model_aliases
from localai.ops import CommandResult
from localai.paths import REPO_ROOT


def test_model_alias_sources_match_health_contract() -> None:
    assert model_aliases.alias_source_map_matches_health_contract()


def test_parse_ollama_list_names_adds_latest_alias() -> None:
    text = "NAME ID SIZE MODIFIED\nqwen:latest abc 1 GB today\nbare abc 1 GB today\n"

    assert model_aliases.parse_ollama_list_names(text) == {
        "qwen:latest",
        "qwen",
        "bare",
    }


def test_model_aliases_missing_sources_match_legacy_warning(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    ollama = Path("C:/fake/ollama.exe")

    monkeypatch.setattr(model_aliases, "ollama_path", lambda: ollama)
    monkeypatch.setattr(Path, "exists", lambda _path: True)
    monkeypatch.setattr(model_aliases, "wait_for_ollama_api", lambda *_args: True)
    monkeypatch.setattr(model_aliases, "get_model_name_set", lambda _ollama: set())

    code, lines = model_aliases.collect_model_aliases_report(
        wait_attempts=1,
        wait_interval_sec=0,
    )

    assert code == 1
    assert lines[0] == (
        "WARNING: Skipping deep-thinking-qwen3.6: source model "
        "'qwen3.6-thinklight-grounded' is missing."
    )
    assert len(lines) == len(model_aliases.ALIASES)


def test_lenient_skips_missing_sources_without_failing(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # A clean / tier-B box lacks this box's model zoo. With --lenient a missing
    # source is skipped, NOT fatal, so `localai start` does not die at aliases
    # (audit finding 2 / ref-box #2).
    ollama = Path("C:/fake/ollama.exe")
    monkeypatch.setattr(model_aliases, "ollama_path", lambda: ollama)
    monkeypatch.setattr(Path, "exists", lambda _path: True)
    monkeypatch.setattr(model_aliases, "wait_for_ollama_api", lambda *_args: True)
    monkeypatch.setattr(model_aliases, "get_model_name_set", lambda _ollama: set())

    code, lines = model_aliases.collect_model_aliases_report(
        lenient=True, wait_attempts=1, wait_interval_sec=0
    )

    assert code == 0  # missing sources are non-fatal under lenient
    assert any("Skipping deep-thinking-qwen3.6" in line for line in lines)


def test_lenient_keeps_real_cp_failure_fatal(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The guard that lenient must NOT weaken this box: a real `ollama cp` failure
    # (source present but the copy errors) is still fatal even under lenient.
    ollama = Path("C:/fake/ollama.exe")
    present = {"qwen3.6-thinklight-grounded"}  # only one alias source exists

    def failing_cp(args: list[str], *, cwd: Path, timeout_sec: int) -> CommandResult:
        return CommandResult(tuple(args), 1, "", "cp failed: disk full")

    monkeypatch.setattr(model_aliases, "ollama_path", lambda: ollama)
    monkeypatch.setattr(Path, "exists", lambda _path: True)
    monkeypatch.setattr(model_aliases, "wait_for_ollama_api", lambda *_args: True)
    monkeypatch.setattr(model_aliases, "get_model_name_set", lambda _ollama: present)
    monkeypatch.setattr(model_aliases, "run_command", failing_cp)

    code, lines = model_aliases.collect_model_aliases_report(
        lenient=True, wait_attempts=1, wait_interval_sec=0
    )

    assert code == 1  # a real copy failure stays fatal under lenient
    assert any("Failed to create" in line for line in lines)


def test_model_aliases_dry_run_does_not_copy(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    ollama = Path("C:/fake/ollama.exe")
    existing = {row.source for row in model_aliases.ALIASES}

    def fail_run_command(*_args: object, **_kwargs: object) -> CommandResult:
        raise AssertionError("dry-run must not run ollama cp")

    monkeypatch.setattr(model_aliases, "ollama_path", lambda: ollama)
    monkeypatch.setattr(Path, "exists", lambda _path: True)
    monkeypatch.setattr(model_aliases, "wait_for_ollama_api", lambda *_args: True)
    monkeypatch.setattr(model_aliases, "get_model_name_set", lambda _ollama: existing)
    monkeypatch.setattr(model_aliases, "run_command", fail_run_command)

    code, lines = model_aliases.collect_model_aliases_report(
        dry_run=True,
        wait_attempts=1,
        wait_interval_sec=0,
    )

    assert code == 0
    assert lines[0].startswith("[dry-run] would alias deep-thinking-qwen3.6")
    assert len(lines) == len(model_aliases.ALIASES)


def test_model_aliases_live_copy_uses_native_ollama(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    ollama = Path("C:/fake/ollama.exe")
    existing = {row.source for row in model_aliases.ALIASES}
    calls: list[list[str]] = []

    def fake_run_command(
        args: list[str],
        *,
        cwd: Path,
        timeout_sec: int,
    ) -> CommandResult:
        calls.append(args)
        assert cwd == REPO_ROOT
        assert timeout_sec == 120
        return CommandResult(tuple(args), 0, "", "")

    monkeypatch.setattr(model_aliases, "ollama_path", lambda: ollama)
    monkeypatch.setattr(Path, "exists", lambda _path: True)
    monkeypatch.setattr(model_aliases, "wait_for_ollama_api", lambda *_args: True)
    monkeypatch.setattr(model_aliases, "get_model_name_set", lambda _ollama: existing)
    monkeypatch.setattr(model_aliases, "run_command", fake_run_command)

    code, lines = model_aliases.collect_model_aliases_report(
        wait_attempts=1,
        wait_interval_sec=0,
    )

    assert code == 0
    assert calls[0] == [
        str(ollama),
        "cp",
        "qwen3.6-thinklight-grounded",
        "deep-thinking-qwen3.6",
    ]
    assert lines[0].startswith("[alias] deep-thinking-qwen3.6")
