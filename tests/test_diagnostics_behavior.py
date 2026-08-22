from __future__ import annotations

import json

import pytest

from localai import diagnostics

# The report is a support artefact a novice pastes into a chat window, so the
# behaviour that matters is: it must not leak identity or secrets, it must stay
# small, and no probe may be able to make it hang or raise.

SECRET_MARKERS = (
    "sk-",
    "api_key",
    "API_KEY",
    "password",
    "token",
    "OPENAI",
    "WEBUI_SECRET",
)


def test_scrub_removes_the_account_name(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("USERNAME", "jidan")
    monkeypatch.delenv("USER", raising=False)
    out = diagnostics.scrub("model loaded for jidan on this box")
    assert "jidan" not in out
    assert "<user>" in out


def test_scrub_is_case_insensitive_about_the_account_name(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("USERNAME", "jidan")
    assert "Jidan" not in diagnostics.scrub("failed for Jidan")


def test_scrub_replaces_the_home_directory_prefix(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("USERPROFILE", r"C:\Users\jidan")
    monkeypatch.setenv("USERNAME", "jidan")
    out = diagnostics.scrub(r"could not open C:\Users\jidan\Documents\notes.txt")
    assert "jidan" not in out
    assert "<home>" in out


def test_scrub_redacts_a_different_profile_on_the_same_box(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The prefix pass only knows THIS account; the backstop must still catch
    # another human's name appearing in a path inside third-party error text.
    monkeypatch.setenv("USERPROFILE", r"C:\Users\jidan")
    monkeypatch.setenv("USERNAME", "jidan")
    out = diagnostics.scrub(r"denied: C:\Users\amanda\AppData\Local\thing.log")
    assert "amanda" not in out


def test_scrub_handles_forward_slash_paths(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("USERPROFILE", r"C:\Users\jidan")
    monkeypatch.setenv("USERNAME", "jidan")
    assert "jidan" not in diagnostics.scrub("path C:/Users/jidan/thing")


def test_scrub_leaves_ordinary_text_alone(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("USERNAME", "jidan")
    text = "Docker daemon not reachable on npipe"
    assert diagnostics.scrub(text) == text


def test_short_account_names_do_not_scrub_unrelated_words(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # A 2-char USERNAME like "jo" must not blank out every "jo" in the report.
    monkeypatch.setenv("USERNAME", "jo")
    assert diagnostics.scrub("job finished") == "job finished"


def _fake_report() -> dict[str, object]:
    return {
        "afk_ai_version": "0.1.7",
        "python": "3.12.5",
        "windows": "Windows 11 (build 10.0.26200)",
        "hardware": {
            "source": "system_info",
            "cpu": "Intel64 Family 6",
            "ram_gb": 31.6,
            "gpus": [{"name": "NVIDIA GeForce RTX 4080", "vram_gb": 12.0}],
            "selected_runtime": "cuda",
        },
        "disk_free_gb": 128.5,
        "installer": {
            "present": True,
            "phases_done": ["vet", "python"],
            "pending_reboot": False,
            "tier": "GPU12",
            "vram_budget_gb": 12,
            "model_tag": "qwen3.5:9b-32k",
            "model_num_ctx": 32768,
        },
        "ollama": {"ok": True, "detail": ""},
        "docker": {"ok": False, "detail": "daemon not reachable"},
        "health": {"ran": True, "exit_code": 1, "problem_lines": ["[FAIL] Docker"]},
    }


def test_report_includes_the_fields_support_actually_needs() -> None:
    text = "\n".join(diagnostics.format_report(_fake_report()))
    for expected in (
        "0.1.7",
        "Windows 11",
        "Intel64",
        "31.6",
        "128.5",
        "RTX 4080",
        "GPU12",
        "qwen3.5:9b-32k",
    ):
        assert expected in text, expected


def test_report_states_service_status_plainly() -> None:
    text = "\n".join(diagnostics.format_report(_fake_report()))
    assert "Ollama" in text
    assert "NOT running" in text  # docker is down in the fixture


def test_report_carries_no_secret_markers() -> None:
    # Skip the reassurance banner, which legitimately says the words "prompts"
    # and "passwords" while promising not to include them.
    lines = diagnostics.format_report(_fake_report())
    body = "\n".join(line for line in lines if not line.startswith("(safe to send"))
    for marker in SECRET_MARKERS:
        assert marker not in body, marker


def test_report_is_bounded() -> None:
    lines = diagnostics.format_report(_fake_report())
    assert len("\n".join(lines)) <= diagnostics.MAX_REPORT_CHARS


def test_report_truncates_an_oversized_body() -> None:
    body = _fake_report()
    body["health"] = {
        "ran": True,
        "exit_code": 1,
        "problem_lines": ["x" * 400 for _ in range(200)],
    }
    lines = diagnostics.format_report(body)
    assert len("\n".join(lines)) <= diagnostics.MAX_REPORT_CHARS


def test_every_emitted_line_is_scrubbed(monkeypatch: pytest.MonkeyPatch) -> None:
    # Identity embedded by a THIRD-PARTY collector must still be removed, which
    # is the whole reason scrub runs at the single emission point.
    monkeypatch.setenv("USERNAME", "jidan")
    monkeypatch.setenv("USERPROFILE", r"C:\Users\jidan")
    body = _fake_report()
    body["docker"] = {"ok": False, "detail": r"open C:\Users\jidan\.docker failed"}
    text = "\n".join(diagnostics.format_report(body))
    assert "jidan" not in text


def test_installer_state_reads_only_allow_listed_keys(
    tmp_path: pytest.TempPathFactory, monkeypatch: pytest.MonkeyPatch
) -> None:
    # A future installer key holding user content must not reach the report.
    import pathlib

    root = pathlib.Path(str(tmp_path))
    (root / "installer").mkdir(parents=True)
    (root / "installer" / "installer-state.json").write_text(
        json.dumps(
            {
                "phases_done": ["vet"],
                "hardware": {"tier": "CPU", "vram_gb": None},
                "models": {"chat": {"tag": "t", "num_ctx": 8192}},
                "user_prompt": "MY PRIVATE CHAT TEXT",
                "api_token": "sk-should-never-appear",
            }
        ),
        encoding="utf-8",
    )
    monkeypatch.setattr(diagnostics, "REPO_ROOT", root)
    state = diagnostics._installer_state()
    assert state["tier"] == "CPU"
    assert "MY PRIVATE CHAT TEXT" not in json.dumps(state)
    assert "sk-should-never-appear" not in json.dumps(state)


def test_missing_installer_state_is_not_an_error(
    tmp_path: pytest.TempPathFactory, monkeypatch: pytest.MonkeyPatch
) -> None:
    import pathlib

    monkeypatch.setattr(diagnostics, "REPO_ROOT", pathlib.Path(str(tmp_path)))
    assert diagnostics._installer_state() == {"present": False}


def test_hardware_falls_back_when_hwcaps_is_absent(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # hwcaps ships on a different branch; the shipping baseline must still
    # produce real CPU/RAM/GPU rather than "unknown".
    monkeypatch.setattr(diagnostics, "_hardware_from_hwcaps", lambda: None)
    monkeypatch.setattr(diagnostics, "_gpu_name", lambda: "NVIDIA Test GPU")
    monkeypatch.setattr(
        "localai.system_info.collect_system",
        lambda: {"ramTotalGb": 16.0, "vramTotalGb": 8.0},
    )
    hw = diagnostics._hardware()
    assert hw["source"] == "system_info"
    assert hw["ram_gb"] == 16.0
    assert hw["gpus"][0]["name"] == "NVIDIA Test GPU"


def test_a_failing_hardware_probe_never_raises(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def boom() -> None:
        raise RuntimeError("probe exploded")

    monkeypatch.setattr(diagnostics, "_hardware_from_hwcaps", lambda: None)
    monkeypatch.setattr("localai.system_info.collect_system", boom)
    hw = diagnostics._hardware()
    assert "error" in hw


def test_health_timeout_degrades_instead_of_hanging(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The full sweep took >120s live; a support button cannot block on that.
    monkeypatch.setattr(diagnostics, "HEALTH_TIMEOUT_SEC", 0.2)

    def slow() -> tuple[int, list[str]]:
        import time

        time.sleep(5)
        return 0, []

    monkeypatch.setattr("localai.health.collect_health_report", slow)
    result = diagnostics._service_health()
    assert result["ran"] is False
    assert "still running" in result["detail"]


def test_ollama_status_probes_the_api_not_the_version_flag(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # `ollama --version` exits 0 with the daemon down, which made the report
    # claim "reachable" about a dead engine.
    called: list[str] = []

    def fake_run(argv: list[str], **kwargs: object) -> None:
        called.append(argv[0])
        raise AssertionError("must not shell out for reachability")

    monkeypatch.setattr(diagnostics, "run_command", fake_run)
    status = diagnostics._ollama_status()
    assert called == []
    assert status["ok"] in (True, False)


def test_report_never_contains_environment_values(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("WEBUI_SECRET_KEY", "super-secret-value")
    text = "\n".join(diagnostics.format_report(_fake_report()))
    assert "super-secret-value" not in text


def test_control_center_reports_the_in_tree_version_not_stale_metadata(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Live drift that motivated this: dist metadata said 0.1.0 while the running
    # source said 0.1.1 and the shipped tag was v0.1.6, so the Control Center
    # advertised a release the customer was not running.
    from localai import dashboard

    monkeypatch.setattr(
        dashboard, "package_version", lambda _name: "0.0.1-stale-metadata"
    )
    from localai import __version__

    assert dashboard._app_version() == __version__


def test_cli_and_control_center_agree_on_the_version() -> None:
    from localai import __version__, dashboard

    assert dashboard._app_version() == __version__


def test_package_version_matches_pyproject() -> None:
    # Duplicated deliberately from test_python_scaffold: the release contract is
    # the thing this branch changed, so it gets a guard next to the change.
    import pathlib
    import tomllib

    from localai import __version__

    root = pathlib.Path(__file__).resolve().parents[1]
    data = tomllib.loads((root / "pyproject.toml").read_text(encoding="utf-8"))
    assert data["project"]["version"] == __version__


# --------------------------------------------------------------------------
# Adversarial privacy regressions.
#
# Reconciliation with the independent Codex review, which found that the
# scrubber only knew about Windows home paths and the account name. Every case
# below was reproduced as a real leak against this implementation before the
# fix: free text reaches the report through two channels (a command's
# stdout/stderr `detail`, and the health collector's problem lines), and
# neither was sanitised beyond home/username.
# --------------------------------------------------------------------------

SECRET_VALUES = [
    "SEARXNG_SECRET=hunter2",
    "token = bearer-private",
    "password: swordfish",
    "api_key=sk-private",
    "API-KEY=another-private-value",
    "Authorization: Bearer abc123xyz",
    'WEBUI_SECRET_KEY = "quoted-secret"',
]

NETWORK_IDENTIFIERS = [
    "100.64.12.34",
    "192.168.1.8",
    "10.0.0.7",
    "8.8.8.8",
    "2001:db8::dead:beef",
    "fd7a:115c:a1e0::1",
    "alice-pc.tail123.ts.net",
]

FOREIGN_HOME_PATHS = [
    "/home/alice/localai/.env",
    "/Users/Alice/AFK-AI",
]


def _body_with(detail: str = "", health_line: str = "") -> dict[str, object]:
    body = _fake_report()
    if detail:
        body["docker"] = {"ok": False, "detail": detail}
    if health_line:
        body["health"] = {"ran": True, "exit_code": 1, "problem_lines": [health_line]}
    return body


@pytest.mark.parametrize("candidate", SECRET_VALUES)
def test_credential_values_never_survive_command_detail(candidate: str) -> None:
    text = "\n".join(diagnostics.format_report(_body_with(detail=candidate)))
    value = candidate.split("=")[-1].split(":")[-1].strip().strip('"')
    assert value not in text, candidate


@pytest.mark.parametrize("candidate", SECRET_VALUES)
def test_credential_values_never_survive_health_lines(candidate: str) -> None:
    text = "\n".join(diagnostics.format_report(_body_with(health_line=candidate)))
    value = candidate.split("=")[-1].split(":")[-1].strip().strip('"')
    assert value not in text, candidate


@pytest.mark.parametrize("addr", NETWORK_IDENTIFIERS)
def test_non_loopback_network_identifiers_are_redacted(addr: str) -> None:
    for body in (_body_with(detail=addr), _body_with(health_line=addr)):
        text = "\n".join(diagnostics.format_report(body))
        assert addr.casefold() not in text.casefold(), addr


@pytest.mark.parametrize("path", FOREIGN_HOME_PATHS)
def test_posix_and_mac_home_paths_are_redacted(path: str) -> None:
    text = "\n".join(diagnostics.format_report(_body_with(detail=path)))
    assert path not in text
    assert "alice" not in text.casefold()


def test_loopback_addresses_are_preserved_because_support_needs_them() -> None:
    # Redaction must not cost the report its usefulness: 127.0.0.1 and ::1 are
    # the addresses this product is SUPPOSED to be bound to.
    text = "\n".join(
        diagnostics.format_report(_body_with(detail="bound 127.0.0.1:11434 and ::1"))
    )
    assert "127.0.0.1" in text


def test_the_machine_hostname_is_redacted() -> None:
    import platform

    node = platform.node()
    if not node or len(node) < 3:
        pytest.skip("no usable hostname on this box")
    text = "\n".join(diagnostics.format_report(_body_with(detail=f"host {node} up")))
    assert node.casefold() not in text.casefold()


def test_scrub_is_applied_at_the_final_output_boundary() -> None:
    # Even a caller-injected report body - not just probe output - is sanitised,
    # because scrub runs on the formatted lines rather than on each collector.
    body = _fake_report()
    body["windows"] = "Windows 11 token=boundary-secret at 192.168.5.5"
    text = "\n".join(diagnostics.format_report(body))
    assert "boundary-secret" not in text
    assert "192.168.5.5" not in text


def test_a_malformed_version_detail_fails_closed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # A probe returning junk (or a secret) instead of a version must collapse to
    # a fixed word rather than being pasted into the report.
    class Result:
        code = 0
        stdout = "29.7.2\nTOKEN=leaked-by-probe"
        stderr = ""

    monkeypatch.setattr(diagnostics, "run_command", lambda *a, **k: Result())
    status = diagnostics._docker_status()
    assert "leaked-by-probe" not in str(status)


def test_loopback_probe_does_not_follow_redirects() -> None:
    # Following a 3xx off 127.0.0.1 would make an outbound request to whatever
    # host answered, breaking the loopback-only posture.
    opener = diagnostics._no_redirect_opener()
    handlers = [type(h).__name__ for h in opener.handlers]
    assert any("NoRedirect" in name for name in handlers)


# --------------------------------------------------------------------------
# Adversarial privacy regressions, round 2.
#
# Clean-machine validation of 0862929 reproduced these as real leaks. The
# credential rule matched a key name as one `[A-Za-z0-9_.-]` run, so a key
# written as a PHRASE ("api key = ...") only redacted when its FINAL word
# carried a keyword - and bare "key" was not a keyword at all, because a
# substring rule containing it would have swallowed "monkey" and "keyboard".
# Credentials embedded in URL userinfo had no rule whatsoever.
# --------------------------------------------------------------------------

PHRASE_SECRETS = [
    ("api key = value", "value"),
    ("API KEY: value", "value"),
    ("secret key = value", "value"),
    ("access key=value", "value"),
    ("Api Key\t=\tv7", "v7"),
    ("api  key  =  double-spaced", "double-spaced"),
    ("client secret : shhh", "shhh"),
    ("auth token = t0ken", "t0ken"),
    ("registry auth key = deadbeef", "deadbeef"),
]

URL_USERINFO_SECRETS = [
    ("http://user:pw-s3cr3t@example.com/x", "pw-s3cr3t"),
    ("https://admin:hunter2@registry.local/v2", "hunter2"),
    ("pull failed: https://bob:s3cr3t@proxy.internal:8080/", "s3cr3t"),
]

#: Ordinary English that merely CONTAINS a keyword must survive: a report that
#: blanks out unrelated prose stops being diagnostically useful.
NON_SECRET_ASSIGNMENTS = [
    "monkey = banana",
    "keyboard = mechanical",
    "donkey: grey",
    "turnkey = yes",
    "passable = true",
    "authentic = yes",
]

#: Plurals of real credential keys stay redacted - under-redacting a genuine
#: secret is the expensive direction.
PLURAL_SECRET_KEYS = [
    ("cookies = a=b; c=d", "a=b"),
    ("sessions = live-session-id", "live-session-id"),
    ("api keys = k1,k2", "k1,k2"),
]


@pytest.mark.parametrize(("candidate", "secret"), PHRASE_SECRETS)
def test_phrase_form_credential_keys_are_redacted(
    candidate: str, secret: str
) -> None:
    for body in (_body_with(detail=candidate), _body_with(health_line=candidate)):
        text = "\n".join(diagnostics.format_report(body))
        assert secret not in text, candidate


@pytest.mark.parametrize(("candidate", "secret"), URL_USERINFO_SECRETS)
def test_credentials_in_url_userinfo_are_redacted(
    candidate: str, secret: str
) -> None:
    for body in (_body_with(detail=candidate), _body_with(health_line=candidate)):
        text = "\n".join(diagnostics.format_report(body))
        assert secret not in text, candidate


@pytest.mark.parametrize("candidate", NON_SECRET_ASSIGNMENTS)
def test_ordinary_words_containing_a_keyword_are_not_treated_as_secrets(
    candidate: str,
) -> None:
    assert diagnostics.scrub(candidate) == candidate


@pytest.mark.parametrize(("candidate", "secret"), PLURAL_SECRET_KEYS)
def test_plural_credential_keys_are_still_redacted(
    candidate: str, secret: str
) -> None:
    assert secret not in diagnostics.scrub(candidate), candidate
