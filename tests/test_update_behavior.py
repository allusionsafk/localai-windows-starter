from __future__ import annotations

from datetime import datetime
from pathlib import Path
from urllib.error import URLError

import pytest

from localai import update
from localai.ops import CommandResult
from localai.paths import REPO_ROOT


def test_update_check_docker_down_offline_release_path(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    ollama = Path("C:/fake/Ollama/ollama.exe")
    original_exists = Path.exists
    saved_state: list[update.UpdateState] = []
    log_calls: list[dict[str, object]] = []

    def fake_exists(path: Path) -> bool:
        if path == ollama:
            return True
        return original_exists(path)

    def fake_write_update_log(**kwargs: object) -> None:
        log_calls.append(kwargs)

    monkeypatch.setattr(update, "docker_running", lambda timeout_sec: False)
    monkeypatch.setattr(update, "ollama_path", lambda: ollama)
    monkeypatch.setattr(Path, "exists", fake_exists)
    monkeypatch.setattr(
        update,
        "current_ollama_version",
        lambda _ollama, timeout_sec: "0.9.0",
    )
    monkeypatch.setattr(
        update,
        "latest_github_release",
        lambda _repo: (_ for _ in ()).throw(URLError("offline")),
    )
    monkeypatch.setattr(update, "load_state", lambda: update.UpdateState({}))
    monkeypatch.setattr(update, "save_state", lambda state: saved_state.append(state))
    monkeypatch.setattr(update, "write_update_log", fake_write_update_log)

    code, lines = update.collect_update_report(
        mode="Check",
        quiet=True,
        now=datetime(2026, 6, 21, 21, 12, 0),
    )

    assert code == 0
    assert lines[:-1] == [
        "",
        "==== localai updater ====  mode: Check   2026-06-21 21:12",
        "    Docker is not running - skipping container checks/updates.",
        "[*] Checking Ollama runtime...",
        "    could not check Ollama releases (offline?).",
        "",
    ]
    assert lines[-1].endswith("s. Log: logs\\update-log.md")
    assert saved_state[0].last_check == "2026-06-21T21:12:00"
    assert log_calls[0]["notes"] == [
        "Docker is not running - skipping container checks/updates.",
        "could not check Ollama releases (offline?).",
    ]
    assert log_calls[0]["ow_status"] == "skipped (Docker not running)"


def test_update_manual_notifications_track_new_versions() -> None:
    state = update.UpdateState(manual_notified={"ollama": "v0.9.0"})
    manual = [
        update.ManualItem(
            name="Ollama runtime",
            key="ollama",
            current="0.9.0",
            latest="v0.9.1",
            how="restart Ollama",
        )
    ]

    new_manual = update.update_manual_notifications(state, manual)

    assert new_manual == manual
    assert state.manual_notified == {"ollama": "v0.9.1"}
    assert update.update_manual_notifications(state, manual) == []


def test_update_apply_dry_run_previews_safe_steps(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    log_calls: list[dict[str, object]] = []

    monkeypatch.setattr(
        update,
        "write_update_log",
        lambda **kwargs: log_calls.append(kwargs),
    )

    code, lines = update.collect_update_report(
        mode="Apply",
        dry_run=True,
        now=datetime(2026, 6, 22, 12, 0, 0),
    )

    assert code == 0
    assert lines == [
        "",
        "==== localai updater ====  mode: Apply   2026-06-22 12:00",
        "[dry-run] No backup, containers, images, models, or model "
        "aliases will be changed.",
        "[+] Backing up Open WebUI data...",
        "    would run: localai backup",
        "[+] Refreshing Docker images and containers...",
        "    would run: docker compose pull",
        "    would run: docker compose up -d",
        "    would run: docker image prune -f",
        "[+] Refreshing Ollama models (incremental)...",
        "    would run: ollama pull x7 bases, rebuild grounded wrappers if changed",
        "[+] Refreshing purpose-based model aliases...",
        "    would run: localai model-aliases",
        "",
        "[OK] Apply dry-run complete. Log: logs\\update-log.md",
    ]
    assert log_calls[0]["ow_status"] == "dry-run apply preview"


def test_update_auto_is_gated() -> None:
    assert update.collect_update_report(mode="Auto") == (
        2,
        ["localai update --mode Auto is not ported to Python yet."],
    )


def test_update_apply_runs_backup_docker_models_and_aliases(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    fake_ollama = Path("C:/fake/Ollama/ollama.exe")
    original_exists = Path.exists
    calls: list[tuple[tuple[str, ...], int]] = []
    log_calls: list[dict[str, object]] = []

    names = [m.base for m in update.APPLY_MODELS] + [
        w.grounded for m in update.APPLY_MODELS for w in m.wrappers
    ]
    listing = "NAME    ID\n" + "\n".join(
        f"{name}    id{i}" for i, name in enumerate(names)
    )

    def fake_exists(path: Path) -> bool:
        if path == fake_ollama:
            return True
        return original_exists(path)

    def fake_run_command(
        args: list[str],
        *,
        cwd: Path,
        timeout_sec: int,
    ) -> CommandResult:
        calls.append((tuple(args), timeout_sec))
        assert cwd == REPO_ROOT
        if args[1:2] == ["list"]:
            return CommandResult(tuple(args), 0, listing, "")
        return CommandResult(tuple(args), 0, "ok\n", "")

    monkeypatch.setattr(
        update,
        "collect_backup_report",
        lambda timeout_sec: (0, ["[OK] Backup complete"]),
    )
    monkeypatch.setattr(update, "ollama_path", lambda: fake_ollama)
    monkeypatch.setattr(Path, "exists", fake_exists)
    monkeypatch.setattr(update, "run_command", fake_run_command)
    monkeypatch.setattr(
        update, "collect_model_aliases_report", lambda: (0, ["[alias] one -> two"])
    )
    monkeypatch.setattr(update, "load_state", lambda: update.UpdateState({}))
    monkeypatch.setattr(update, "save_state", lambda state: None)
    monkeypatch.setattr(
        update, "write_update_log", lambda **kwargs: log_calls.append(kwargs)
    )

    code, lines = update.collect_update_report(
        mode="Apply",
        now=datetime(2026, 6, 22, 12, 1, 0),
        docker_timeout_sec=9,
    )

    commands = [args for args, _ in calls]
    assert code == 0
    assert ("docker", "compose", "pull") in commands
    assert ("docker", "compose", "up", "-d") in commands
    assert ("docker", "image", "prune", "-f") in commands
    for model in update.APPLY_MODELS:
        assert (str(fake_ollama), "pull", model.base) in commands
    # nothing changed and every wrapper already exists -> no rebuilds
    assert not any("create" in args for args in commands)
    # docker ops use the generous docker timeout; base pulls use the model one
    assert next(t for a, t in calls if a == ("docker", "compose", "pull")) == 9
    assert (
        next(t for a, t in calls if a == ("docker", "image", "prune", "-f"))
        == update.IMAGE_PRUNE_TIMEOUT_SEC
    )
    assert (
        next(t for a, t in calls if a[1:2] == ("pull",) and a[0] == str(fake_ollama))
        == update.MODEL_PULL_TIMEOUT_SEC
    )
    assert "    [alias] one -> two" in lines
    assert lines[-1] == "[OK] Apply complete. Log: logs\\update-log.md"
    assert log_calls[0]["ow_status"] == "applied safe updates"


def test_apply_one_model_rebuilds_changed_base(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    fake_ollama = Path("C:/fake/ollama.exe")
    base_ids = iter(["idA", "idB"])
    commands: list[tuple[str, ...]] = []
    modelfile = tmp_path / "wrap.Modelfile"
    modelfile.write_text("FROM base", encoding="utf-8")

    def fake_get_id(ollama: Path, name: str) -> str:
        if name == "base":
            return next(base_ids)
        return ""

    def fake_run_command(
        args: list[str],
        *,
        cwd: Path,
        timeout_sec: int,
    ) -> CommandResult:
        commands.append(tuple(args))
        return CommandResult(tuple(args), 0, "ok\n", "")

    monkeypatch.setattr(update, "get_ollama_id", fake_get_id)
    monkeypatch.setattr(update, "run_command", fake_run_command)
    monkeypatch.setattr(update, "repo_path", lambda *parts: modelfile)

    model = update.ApplyModel(
        "base", (update.ApplyWrapper("base-grounded", "wrap.Modelfile"),)
    )
    lines: list[str] = []
    failures = update.apply_one_model(fake_ollama, model, lines)

    assert failures == 0
    assert (str(fake_ollama), "pull", "base") in commands
    assert (
        str(fake_ollama),
        "create",
        "base-grounded",
        "-f",
        str(modelfile),
    ) in commands


def test_apply_one_model_pull_failure_skips_rebuild(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    fake_ollama = Path("C:/fake/ollama.exe")
    commands: list[tuple[str, ...]] = []

    def fake_run_command(
        args: list[str],
        *,
        cwd: Path,
        timeout_sec: int,
    ) -> CommandResult:
        commands.append(tuple(args))
        if args[1:2] == ["pull"]:
            return CommandResult(tuple(args), 1, "", "boom\n")
        return CommandResult(tuple(args), 0, "ok\n", "")

    monkeypatch.setattr(update, "get_ollama_id", lambda ollama, name: "id")
    monkeypatch.setattr(update, "run_command", fake_run_command)

    model = update.ApplyModel(
        "base", (update.ApplyWrapper("base-grounded", "wrap.Modelfile"),)
    )
    lines: list[str] = []
    failures = update.apply_one_model(fake_ollama, model, lines)

    assert failures == 1
    assert any("model pull failed" in line for line in lines)
    assert not any("create" in args for args in commands)


def test_update_version_compare() -> None:
    assert update.is_newer("0.9.0", "v0.9.1")
    assert not update.is_newer("0.9.1", "v0.9.1")
    assert update.parse_version("v1.2.3") == (1, 2, 3)


def test_update_check_docker_up_detects_open_webui_and_pins(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    ollama = Path("C:/fake/Ollama/ollama.exe")
    original_exists = Path.exists
    log_calls: list[dict[str, object]] = []

    def fake_exists(path: Path) -> bool:
        if path == ollama:
            return True
        return original_exists(path)

    def fake_release(repo: str) -> str:
        if repo == "ollama/ollama":
            return "v0.9.0"
        if repo == "remsky/Kokoro-FastAPI":
            return "v0.2.4"
        raise AssertionError(f"unexpected repo {repo}")

    monkeypatch.setattr(update, "docker_running", lambda timeout_sec: True)
    monkeypatch.setattr(update, "ollama_path", lambda: ollama)
    monkeypatch.setattr(Path, "exists", fake_exists)
    monkeypatch.setattr(
        update,
        "read_compose_text",
        lambda: "searxng/searxng:2025.1.1\nkokoro-fastapi-cpu:v0.2.4\n",
    )
    monkeypatch.setattr(
        update, "get_image_local_digest", lambda ref, timeout_sec: "sha256:aaa"
    )
    monkeypatch.setattr(
        update, "get_image_remote_digest", lambda ref, timeout_sec: f"sha256:{ref}"
    )
    monkeypatch.setattr(
        update, "current_ollama_version", lambda _ollama, timeout_sec: "0.9.0"
    )
    monkeypatch.setattr(update, "latest_github_release", fake_release)
    monkeypatch.setattr(
        update,
        "http_get_json",
        lambda url, timeout_sec: {"results": [{"name": "2025.6.20"}]},
    )
    monkeypatch.setattr(update, "load_state", lambda: update.UpdateState({}))
    monkeypatch.setattr(update, "save_state", lambda state: None)
    monkeypatch.setattr(
        update, "write_update_log", lambda **kwargs: log_calls.append(kwargs)
    )

    code, lines = update.collect_update_report(
        mode="Check",
        quiet=True,
        now=datetime(2026, 6, 22, 10, 0, 0),
    )

    assert code == 0
    assert "[*] Checking Open WebUI image..." in lines
    assert "    update available" in lines
    assert "    2025.6.20 available (pinned at 2025.1.1)" in lines
    assert "    up to date (v0.2.4)" in lines
    assert log_calls[0]["ow_status"] == "update available"
    manual = log_calls[0]["manual"]
    assert isinstance(manual, list)
    assert [item.key for item in manual] == ["searxng"]


def test_searxng_has_newer_same_date_diff_digest(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    digests = {
        "docker.io/searxng/searxng:2026.6.22-aaa": "sha256:1",
        "docker.io/searxng/searxng:2026.6.22-bbb": "sha256:2",
    }
    monkeypatch.setattr(
        update,
        "get_image_remote_digest",
        lambda ref, *, timeout_sec: digests.get(ref),
    )
    assert update.searxng_has_newer("2026.6.22-aaa", "2026.6.22-bbb", timeout_sec=5)


def test_searxng_has_newer_same_date_same_digest(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        update, "get_image_remote_digest", lambda ref, *, timeout_sec: "sha256:x"
    )
    assert not update.searxng_has_newer(
        "2026.6.22-aaa", "2026.6.22-bbb", timeout_sec=5
    )


def test_searxng_has_newer_older_date_short_circuits(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[str] = []

    def fake(ref: str, *, timeout_sec: int) -> str | None:
        calls.append(ref)
        return "sha256:x"

    monkeypatch.setattr(update, "get_image_remote_digest", fake)
    assert not update.searxng_has_newer("2026.6.22-x", "2026.5.01-y", timeout_sec=5)
    assert calls == []


def test_searxng_has_newer_remote_unavailable_overnotifies(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        update, "get_image_remote_digest", lambda ref, *, timeout_sec: None
    )
    assert update.searxng_has_newer("2026.6.22-aaa", "2026.6.22-bbb", timeout_sec=5)
