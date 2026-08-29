from __future__ import annotations

import inspect
import json
from dataclasses import replace
from datetime import datetime
from pathlib import Path

import pytest

from localai import model_scout, scout_categories
from localai.ops import CommandResult


def test_model_scout_parse_and_fit_moe_candidate() -> None:
    candidate = model_scout.parse_model("unsloth/Qwen3.6-35B-A3B-GGUF")
    budget = model_scout.Budget(ram_gb=32, vram_gb=12, disk_free_gb=100)

    fitted = model_scout.apply_fit(
        candidate,
        budget,
        downloads=1200,
        age=7,
        modified="2026-06-14T00:00:00Z",
    )
    scored = model_scout.score_candidate(fitted)

    assert scored.name == "Qwen3.6-35B-A3B"
    assert scored.total == 35
    assert scored.active == 3
    assert scored.is_moe
    assert scored.family == "qwen"
    # ~21GB of weights does not fit a 12GB card. Being MoE makes the spill
    # cheap, not absent, so the honest verdict is "OK" rather than "Good".
    # (This asserted "Good" while the MoE branch skipped the VRAM comparison.)
    assert scored.verdict == "OK"
    assert scored.size_gb == 21
    assert scored.score > 130


def test_model_scout_special_purpose_models_are_deprioritized() -> None:
    candidate = model_scout.parse_model("bartowski/Foo-Coder-14B-GGUF")
    fitted = model_scout.apply_fit(
        candidate,
        model_scout.Budget(ram_gb=32, vram_gb=12, disk_free_gb=100),
        downloads=10000,
        age=1,
        modified="2026-06-20T00:00:00Z",
    )

    assert model_scout.score_candidate(fitted).score == -1


def test_model_scout_hf_failures_still_exit_success(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def fake_fetch_hf_models(author: str) -> list[object]:
        raise OSError(
            "No connection could be made because the target machine actively "
            "refused it. (127.0.0.1:9)"
        )

    log_calls: list[dict[str, object]] = []
    saved_states: list[dict[str, list[str]]] = []

    monkeypatch.setattr(
        model_scout,
        "get_budget",
        lambda timeout_sec, vram_override=None: model_scout.Budget(32, 12, 62.5),
    )
    monkeypatch.setattr(model_scout, "fetch_hf_models", fake_fetch_hf_models)
    monkeypatch.setattr(model_scout, "load_state", lambda: {"prepared": [], "seen": []})
    monkeypatch.setattr(
        model_scout,
        "save_state",
        lambda state: saved_states.append(state),
    )
    monkeypatch.setattr(
        model_scout,
        "write_model_scout_log",
        lambda **kwargs: log_calls.append(kwargs),
    )
    monkeypatch.setattr(model_scout, "write_scout_groups", lambda groups, **kw: None)

    code, lines = model_scout.collect_model_scout_report(
        mode="Scout",
        top_n=3,
        quiet=True,
        now=datetime(2026, 6, 21, 21, 16),
        probe_timeout_sec=5,
    )

    assert code == 0
    assert lines[:4] == [
        "",
        "==== model scout ====  mode: Scout   2026-06-21 21:16",
        "budget: 12GB VRAM | 32GB RAM | 62.5GB free disk",
        "[*] Discovering recent GGUF releases from: unsloth, bartowski, "
        "lmstudio-community, Qwen, ggml-org",
    ]
    assert lines.count(
        "    HF query failed for unsloth : No connection could be made because "
        "the target machine actively refused it. (127.0.0.1:9)"
    ) == 1
    # Grouped output: one section per category, even when HF returned nothing.
    for category in scout_categories.CATEGORIES:
        assert f"[{category.label}]" in lines
    assert lines[-1] == "[done] log: logs\\model-scout-log.md"
    assert saved_states == [{"prepared": [], "seen": []}]
    notes = log_calls[0]["notes"]
    assert isinstance(notes, list)
    assert len(notes) == len(model_scout.AUTHORS)


def test_scout_prints_a_section_per_category_with_curated_top(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        model_scout,
        "get_budget",
        lambda timeout_sec, vram_override=None: model_scout.Budget(32, 12, 100),
    )
    monkeypatch.setattr(model_scout, "discover_candidates", lambda **kwargs: [])
    monkeypatch.setattr(model_scout, "load_state", lambda: {"prepared": [], "seen": []})
    monkeypatch.setattr(model_scout, "save_state", lambda state: None)
    monkeypatch.setattr(model_scout, "write_model_scout_log", lambda **kwargs: None)
    written: dict[str, object] = {}
    monkeypatch.setattr(
        model_scout,
        "write_scout_groups",
        lambda groups, **kw: written.update(groups=groups),
    )

    code, lines = model_scout.collect_model_scout_report(
        mode="Scout", now=datetime(2026, 7, 8, 12, 0), probe_timeout_sec=5
    )

    assert code == 0
    # Chat shows its curated seed as the top pick.
    assert any("TOP" in line and "9b-32k" in line for line in lines)
    # Voice has no candidates and surfaces the honest note.
    voice_at = lines.index("[Voice]")
    assert any("(none)" in line for line in lines[voice_at : voice_at + 2])
    assert written["groups"]  # cache handed to the writer


def test_scout_lists_dropped_models_for_vram(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    huge = _built("Qwen/Qwen3.5-43B-GGUF", downloads=5000, age_days=5)
    monkeypatch.setattr(
        model_scout,
        "get_budget",
        lambda timeout_sec, vram_override=None: model_scout.Budget(32, 12, 100),
    )
    monkeypatch.setattr(model_scout, "discover_candidates", lambda **kwargs: [huge])
    monkeypatch.setattr(model_scout, "load_state", lambda: {"prepared": [], "seen": []})
    monkeypatch.setattr(model_scout, "save_state", lambda state: None)
    monkeypatch.setattr(model_scout, "write_model_scout_log", lambda **kwargs: None)
    monkeypatch.setattr(model_scout, "write_scout_groups", lambda groups, **kw: None)

    _code, lines = model_scout.collect_model_scout_report(
        mode="Scout", now=datetime(2026, 7, 8, 12, 0), probe_timeout_sec=5
    )

    assert any("dropped" in line.lower() and "43B" in line for line in lines)


def test_scout_command_alias_is_registered() -> None:
    from localai import cli

    names = {
        info.name or info.callback.__name__.replace("_", "-")
        for info in cli.app.registered_commands
        if info.callback
    }
    assert "scout" in names  # brief calls it `localai scout`
    assert "model-scout" in names  # original name kept for parity


# ------------------------------------ VRAM budget honesty (audit finding 4)


def test_get_vram_gb_is_none_when_nvidia_smi_absent(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # A friend's AMD/CPU box has no nvidia-smi. The old code returned a false 12
    # here and recommended 9B models that cannot run.
    result = model_scout.CommandResult(("nvidia-smi",), 1, "", "not found\n")
    monkeypatch.setattr(model_scout, "run_command", lambda *a, **k: result)

    assert model_scout.get_vram_gb(timeout_sec=5) is None


def test_get_vram_gb_is_none_on_unparseable_output(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    result = model_scout.CommandResult(("nvidia-smi",), 0, "N/A\n", "")
    monkeypatch.setattr(model_scout, "run_command", lambda *a, **k: result)

    assert model_scout.get_vram_gb(timeout_sec=5) is None


def test_get_vram_gb_parses_and_rounds_to_one_decimal(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # 16376 MiB -> 16.0 (the rounding contract that keeps a nominal-16 GB card in
    # tier S rather than dropping to A; audit finding 15).
    result = model_scout.CommandResult(("nvidia-smi",), 0, "16376\n", "")
    monkeypatch.setattr(model_scout, "run_command", lambda *a, **k: result)

    assert model_scout.get_vram_gb(timeout_sec=5) == 16.0


def test_get_budget_treats_missing_vram_as_zero_not_twelve(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(model_scout, "get_vram_gb", lambda *, timeout_sec: None)
    monkeypatch.setattr(model_scout, "get_ram_gb", lambda *, timeout_sec: 32.0)

    budget = model_scout.get_budget(timeout_sec=5)

    assert budget.vram_gb == 0.0  # -> CPU tier, honest, not a phantom 12 GB card


def test_get_budget_uses_vram_override_without_probing(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The installer passes the vetted tier budget; get_budget must trust it and
    # not probe (works even where nvidia-smi would report a different number).
    def _boom(*, timeout_sec: int) -> float:
        raise AssertionError("get_vram_gb must not be called when overridden")

    monkeypatch.setattr(model_scout, "get_vram_gb", _boom)
    monkeypatch.setattr(model_scout, "get_ram_gb", lambda *, timeout_sec: 32.0)

    budget = model_scout.get_budget(timeout_sec=5, vram_override=6.0)

    assert budget.vram_gb == 6.0


def test_scout_command_exposes_vram_gb_flag() -> None:
    import inspect

    from localai import cli

    scout = next(
        info.callback
        for info in cli.app.registered_commands
        if info.callback and info.name == "scout"
    )
    assert "vram_gb" in inspect.signature(scout).parameters


# --------------------------------------------- prepare at a category's context


def test_grounded_modelfile_bakes_given_ctx() -> None:
    candidate = model_scout.parse_model("Qwen/Qwen3.5-9B-GGUF")
    content = model_scout.grounded_modelfile(
        "Qwen/Qwen3.5-9B-GGUF",
        "Q4_K_M",
        candidate,
        now=datetime(2026, 7, 8),
        num_ctx=32768,
    )
    assert "PARAMETER num_ctx 32768" in content
    assert "PARAMETER num_ctx 8192" not in content


def test_grounded_modelfile_defaults_to_8k() -> None:
    candidate = model_scout.parse_model("Qwen/Qwen3.5-9B-GGUF")
    content = model_scout.grounded_modelfile(
        "Qwen/Qwen3.5-9B-GGUF", "Q4_K_M", candidate, now=datetime(2026, 7, 8)
    )
    assert "PARAMETER num_ctx 8192" in content


def test_grounded_model_name_encodes_nondefault_ctx() -> None:
    candidate = model_scout.parse_model("Qwen/Qwen3.5-9B-GGUF")
    # Constraint #2: warm/UI key num_ctx off the "-NNk" suffix, so a model
    # prepared at 32k must carry it in the name or the first chat reloads.
    assert model_scout.grounded_model_name(candidate, num_ctx=32768).endswith("-32k")
    assert model_scout.grounded_model_name(candidate, num_ctx=16384).endswith("-16k")
    # 8k is the default and stays unsuffixed (keeps existing tags stable).
    assert not model_scout.grounded_model_name(candidate, num_ctx=8192).endswith("k")


def test_prepare_pick_threads_num_ctx_to_modelfile(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    pick = _eligible_candidate()
    monkeypatch.setattr(
        model_scout, "repo_path", lambda *parts: tmp_path.joinpath(*parts)
    )
    monkeypatch.setattr(
        model_scout,
        "select_quant_artefact",
        lambda repo: model_scout.QuantArtefact("Q4_K_M", None),
    )
    monkeypatch.setattr(model_scout, "baseline_model", lambda: "qwen-base")
    monkeypatch.setattr(model_scout, "model_present", lambda model, **kwargs: False)
    monkeypatch.setattr(model_scout, "stop_model", lambda model, **kwargs: None)
    created: list[str] = []

    def fake_run_ollama(args: list[str], **kwargs: object) -> CommandResult:
        if args and args[0] == "create":
            created.append(args[1])
        return CommandResult(("ollama", *args), 0, "", "")

    monkeypatch.setattr(model_scout, "run_ollama", fake_run_ollama)
    monkeypatch.setattr(
        model_scout,
        "measure_speed",
        lambda model, **kwargs: model_scout.BenchResult(40.0, 300, "100% GPU"),
    )

    code = model_scout.prepare_pick(
        pick,
        budget=model_scout.Budget(ram_gb=32, vram_gb=12, disk_free_gb=100),
        state={"prepared": [], "seen": []},
        say=lambda _line: None,
        log=[],
        no_pull=False,
        stream=False,
        now=datetime(2026, 7, 8, 12, 0),
        probe_timeout_sec=5,
        num_ctx=32768,
    )

    assert code == 0
    assert created == ["qwen3.7-30b-a3b-grounded-32k"]
    modelfile = tmp_path / "scout-qwen3.7-30b-a3b.Modelfile"
    assert "PARAMETER num_ctx 32768" in modelfile.read_text(encoding="ascii")


def test_prepare_mode_threads_category_ctx(monkeypatch: pytest.MonkeyPatch) -> None:
    coder = _built("bartowski/Qwen2.5-Coder-14B-GGUF", downloads=9000, age_days=3)
    monkeypatch.setattr(
        model_scout,
        "get_budget",
        lambda timeout_sec, vram_override=None: model_scout.Budget(32, 12, 100),
    )
    monkeypatch.setattr(model_scout, "discover_candidates", lambda **kwargs: [coder])
    monkeypatch.setattr(model_scout, "load_state", lambda: {"prepared": [], "seen": []})
    monkeypatch.setattr(model_scout, "save_state", lambda state: None)
    monkeypatch.setattr(model_scout, "write_model_scout_log", lambda **kwargs: None)
    monkeypatch.setattr(model_scout, "write_scout_groups", lambda groups, **kw: None)
    captured: dict[str, object] = {}

    def fake_prepare(pick: model_scout.Candidate, **kwargs: object) -> int:
        captured["num_ctx"] = kwargs.get("num_ctx")
        captured["pick"] = pick.name
        return 0

    monkeypatch.setattr(model_scout, "prepare_pick", fake_prepare)

    code, _lines = model_scout.collect_model_scout_report(
        mode="Prepare",
        category="coding",
        now=datetime(2026, 7, 8, 12, 0),
        probe_timeout_sec=5,
    )

    assert code == 0
    assert captured["num_ctx"] == 32768  # coding category's target_ctx
    assert "Coder" in str(captured["pick"])


def test_model_scout_promote_stays_gated() -> None:
    assert model_scout.collect_model_scout_report(mode="Promote") == (
        2,
        ["localai model-scout --mode Promote is not ported to Python yet."],
    )


def _eligible_candidate() -> model_scout.Candidate:
    return model_scout.Candidate(
        id="unsloth/Qwen3.7-30B-A3B-GGUF",
        author="unsloth",
        name="Qwen3.7-30B-A3B",
        total=30,
        active=3,
        is_moe=True,
        kind="general",
        reasoning=False,
        family="qwen",
        parse_warning=None,
        downloads=5000,
        age_days=5,
        modified="2026-07-01T00:00:00Z",
        verdict="Good",
        size_gb=18.0,
        fit_why="MoE ~3B active = fast even with CPU offload",
        score=200,
    )


def test_collect_prepare_no_pull_streams_lines_live(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    log_calls: list[dict[str, object]] = []
    monkeypatch.setattr(
        model_scout,
        "get_budget",
        lambda timeout_sec, vram_override=None: model_scout.Budget(32, 12, 100),
    )
    monkeypatch.setattr(
        model_scout,
        "discover_candidates",
        lambda **kwargs: [_eligible_candidate()],
    )
    monkeypatch.setattr(model_scout, "load_state", lambda: {"prepared": [], "seen": []})
    monkeypatch.setattr(model_scout, "save_state", lambda state: None)
    monkeypatch.setattr(
        model_scout,
        "write_model_scout_log",
        lambda **kwargs: log_calls.append(kwargs),
    )
    monkeypatch.setattr(model_scout, "write_scout_groups", lambda groups, **kw: None)
    monkeypatch.setattr(
        model_scout,
        "select_quant_artefact",
        lambda repo: model_scout.QuantArtefact("UD-Q4_K_XL", None),
    )

    echoed: list[str] = []
    code, lines = model_scout.collect_model_scout_report(
        mode="Prepare",
        no_pull=True,
        echo=echoed.append,
        now=datetime(2026, 7, 5, 12, 0),
        probe_timeout_sec=5,
    )

    assert code == 0
    assert echoed == lines
    assert "[+] Quant chosen for 12GB VRAM: UD-Q4_K_XL" in lines
    assert "    (--no-pull: skipping the actual download)" in lines
    assert log_calls[0]["mode"] == "Prepare"
    assert log_calls[0]["prepare_lines"] == []


def test_prepare_pick_skips_pull_when_disk_is_low() -> None:
    said: list[str] = []
    logged: list[str] = []

    code = model_scout.prepare_pick(
        _eligible_candidate(),  # ~18GB pick needs 30GB free
        budget=model_scout.Budget(ram_gb=32, vram_gb=12, disk_free_gb=20),
        state={"prepared": [], "seen": []},
        say=said.append,
        log=logged,
        no_pull=False,
        stream=False,
        now=datetime(2026, 7, 5, 12, 0),
        probe_timeout_sec=5,
    )

    assert code == 0
    assert said[0].startswith("[!] Low disk (need ~30GB, have 20GB)")
    assert logged == ["- SKIPPED pull (low disk): unsloth/Qwen3.7-30B-A3B-GGUF"]


def test_prepare_pick_pulls_grounds_benchmarks_and_records(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    pick = _eligible_candidate()
    state: dict[str, list[str]] = {"prepared": [], "seen": []}
    said: list[str] = []
    logged: list[str] = []
    calls: list[tuple[str, tuple[str, ...]]] = []

    monkeypatch.setattr(
        model_scout, "repo_path", lambda *parts: tmp_path.joinpath(*parts)
    )
    monkeypatch.setattr(
        model_scout,
        "select_quant_artefact",
        lambda repo: model_scout.QuantArtefact("Q4_K_M", None),
    )
    monkeypatch.setattr(model_scout, "baseline_model", lambda: "qwen-base")
    monkeypatch.setattr(
        model_scout, "model_present", lambda model, **kwargs: model == "qwen-base"
    )
    monkeypatch.setattr(
        model_scout,
        "stop_model",
        lambda model, **kwargs: calls.append(("stop", (model,))),
    )

    def fake_run_ollama(args: list[str], **kwargs: object) -> CommandResult:
        calls.append(("ollama", tuple(args)))
        return CommandResult(("ollama", *args), 0, "", "")

    monkeypatch.setattr(model_scout, "run_ollama", fake_run_ollama)
    benches = {
        "qwen3.7-30b-a3b-grounded": model_scout.BenchResult(45.2, 300, "100% GPU"),
        "qwen-base": model_scout.BenchResult(39.0, 300, "100% GPU"),
    }
    monkeypatch.setattr(
        model_scout, "measure_speed", lambda model, **kwargs: benches[model]
    )

    code = model_scout.prepare_pick(
        pick,
        budget=model_scout.Budget(ram_gb=32, vram_gb=12, disk_free_gb=100),
        state=state,
        say=said.append,
        log=logged,
        no_pull=False,
        stream=False,
        now=datetime(2026, 7, 5, 12, 0),
        probe_timeout_sec=5,
    )

    assert code == 0
    assert state["prepared"] == [pick.id]
    assert ("ollama", ("pull", "hf.co/unsloth/Qwen3.7-30B-A3B-GGUF:Q4_K_M")) in calls
    create = next(
        args for kind, args in calls if kind == "ollama" and args[0] == "create"
    )
    assert create[1] == "qwen3.7-30b-a3b-grounded"
    modelfile = tmp_path / "scout-qwen3.7-30b-a3b.Modelfile"
    assert modelfile.exists()
    content = modelfile.read_text(encoding="ascii")
    assert content.startswith("FROM hf.co/unsloth/Qwen3.7-30B-A3B-GGUF:Q4_K_M")
    assert "PARAMETER num_ctx 8192" in content
    assert "PARAMETER top_k 20" in content  # qwen sampling
    assert "TEMPLATE" in content  # qwen chat template
    assert 'SYSTEM """You are a precise, grounded assistant.' in content
    # New model is unloaded before the baseline benchmark loads (RAM safety).
    assert ("stop", ("qwen3.7-30b-a3b-grounded",)) in calls
    assert ("stop", ("qwen-base",)) in calls
    assert logged[0] == (
        "- PREPARED: qwen3.7-30b-a3b-grounded  "
        "FROM hf.co/unsloth/Qwen3.7-30B-A3B-GGUF:Q4_K_M"
    )
    assert any("FASTER than qwen-base (45.2 vs 39 tok/s)" in line for line in logged)
    assert any(
        line.startswith("[OK] qwen3.7-30b-a3b-grounded is ready") for line in said
    )


def test_prepare_pick_reports_pull_failure(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    said: list[str] = []
    logged: list[str] = []
    monkeypatch.setattr(
        model_scout, "repo_path", lambda *parts: tmp_path.joinpath(*parts)
    )
    monkeypatch.setattr(model_scout, "select_quant_artefact", lambda repo: None)
    monkeypatch.setattr(
        model_scout,
        "run_ollama",
        lambda args, **kwargs: CommandResult(
            ("ollama", *args), 1, "", "pull model manifest: file does not exist"
        ),
    )

    code = model_scout.prepare_pick(
        _eligible_candidate(),
        budget=model_scout.Budget(ram_gb=32, vram_gb=12, disk_free_gb=100),
        state={"prepared": [], "seen": []},
        say=said.append,
        log=logged,
        no_pull=False,
        stream=False,
        now=datetime(2026, 7, 5, 12, 0),
        probe_timeout_sec=5,
    )

    assert code == 1
    assert "[+] Quant chosen for 12GB VRAM: Q4_K_M" in said  # fallback quant
    assert logged == [
        "- PREPARE FAILED: unsloth/Qwen3.7-30B-A3B-GGUF - "
        "pull model manifest: file does not exist"
    ]


def test_pull_with_retry_recovers_from_transient_failure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    results = iter(
        [
            CommandResult(("ollama", "pull"), 1, "", "context deadline exceeded"),
            CommandResult(("ollama", "pull"), 1, "", "context deadline exceeded"),
            CommandResult(("ollama", "pull"), 0, "", ""),
        ]
    )
    calls: list[list[str]] = []

    def fake_run_ollama(args: list[str], **kwargs: object) -> CommandResult:
        calls.append(args)
        return next(results)

    monkeypatch.setattr(model_scout, "run_ollama", fake_run_ollama)
    said: list[str] = []

    result = model_scout.pull_with_retry(
        "unsloth/Foo-GGUF", "Q4_K_M", stream=True, say=said.append
    )

    assert result.code == 0
    assert len(calls) == 3  # failed twice, third succeeded
    assert sum("retrying" in line for line in said) == 2


def test_pull_with_retry_gives_up_after_attempts(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def always_fail(args: list[str], **kwargs: object) -> CommandResult:
        return CommandResult(tuple(args), 1, "", "context deadline exceeded")

    monkeypatch.setattr(model_scout, "run_ollama", always_fail)
    calls = 0

    def counting(args: list[str], **kwargs: object) -> CommandResult:
        nonlocal calls
        calls += 1
        return CommandResult(tuple(args), 1, "", "context deadline exceeded")

    monkeypatch.setattr(model_scout, "run_ollama", counting)

    result = model_scout.pull_with_retry(
        "unsloth/Foo-GGUF", "Q4_K_M", stream=True, say=lambda _line: None, attempts=4
    )

    assert result.code == 1
    assert calls == 4  # one initial + three retries, then gives up


def test_best_quant_prefers_q4_k_m(monkeypatch: pytest.MonkeyPatch) -> None:
    tree = [
        {"path": "model-IQ4_XS.gguf"},
        {"path": "model-Q4_K_M.gguf"},
        {"path": "README.md"},
    ]
    monkeypatch.setattr(model_scout, "fetch_hf_tree", lambda repo: tree)
    assert model_scout.best_quant("x/y") == "Q4_K_M"


def test_best_quant_falls_back_to_first_seen(monkeypatch: pytest.MonkeyPatch) -> None:
    tree = [{"path": "model-Q8_0.gguf"}, {"path": "model-Q5_K_M.gguf"}]
    monkeypatch.setattr(model_scout, "fetch_hf_tree", lambda repo: tree)
    assert model_scout.best_quant("x/y") == "Q8_0"


def test_best_quant_is_none_when_the_api_fails(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def boom(repo: str) -> list[object]:
        raise OSError("HF down")

    monkeypatch.setattr(model_scout, "fetch_hf_tree", boom)
    assert model_scout.best_quant("x/y") is None


def test_baseline_model_reads_compose_default(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    (tmp_path / "docker-compose.yml").write_text(
        "      - DEFAULT_MODELS=my-daily-driver:latest\n", encoding="utf-8"
    )
    monkeypatch.setattr(
        model_scout, "repo_path", lambda *parts: tmp_path.joinpath(*parts)
    )
    assert model_scout.baseline_model() == "my-daily-driver:latest"


def test_baseline_model_falls_back_without_compose(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setattr(
        model_scout, "repo_path", lambda *parts: tmp_path.joinpath(*parts)
    )
    assert model_scout.baseline_model() == model_scout.FALLBACK_BASELINE


def test_model_scout_ram_probe_uses_native_total_memory(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        model_scout,
        "get_total_physical_memory_bytes",
        lambda: 32 * 1024**3,
    )

    assert model_scout.get_ram_gb(timeout_sec=1) == 32


def test_model_scout_ram_probe_falls_back_to_zero(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(model_scout, "get_total_physical_memory_bytes", lambda: None)

    assert model_scout.get_ram_gb(timeout_sec=1) == 0


# ---------------------------------------------------------------- KV/VRAM math


def test_kv_gb_per_1k_buckets_by_total_params() -> None:
    # GQA KV grows with layer count, which tracks total params. Bucket edges are
    # inclusive on the upper bound.
    assert model_scout.kv_gb_per_1k(4) == 0.11
    assert model_scout.kv_gb_per_1k(4.5) == 0.16
    assert model_scout.kv_gb_per_1k(14) == 0.16
    assert model_scout.kv_gb_per_1k(15) == 0.20
    assert model_scout.kv_gb_per_1k(32) == 0.20
    assert model_scout.kv_gb_per_1k(70) == 0.26


def test_estimate_kv_gb_scales_with_ctx_parallel_and_dtype() -> None:
    # 9B at 32k, one slot, f16: 0.16 GB/1k * 32 * 1 * 1.0 = 5.12 GB.
    assert model_scout.estimate_kv_gb(9, ctx=32768, parallel=1, kv_factor=1.0) == 5.12
    # A second parallel slot doubles the reservation.
    assert model_scout.estimate_kv_gb(9, ctx=32768, parallel=2, kv_factor=1.0) == 10.24
    # q8_0 cache halves it.
    assert model_scout.estimate_kv_gb(9, ctx=32768, parallel=1, kv_factor=0.5) == 2.56
    # Context scales linearly: half the ctx, half the KV.
    assert model_scout.estimate_kv_gb(9, ctx=16384, parallel=1, kv_factor=1.0) == 2.56


def test_read_num_parallel_reads_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("OLLAMA_NUM_PARALLEL", raising=False)
    assert model_scout.read_num_parallel() == 1  # ollama default on this box
    monkeypatch.setenv("OLLAMA_NUM_PARALLEL", "4")
    assert model_scout.read_num_parallel() == 4
    monkeypatch.setenv("OLLAMA_NUM_PARALLEL", "garbage")
    assert model_scout.read_num_parallel() == 1


def test_read_kv_factor_maps_cache_type(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("OLLAMA_KV_CACHE_TYPE", raising=False)
    assert model_scout.read_kv_factor() == 1.0  # conservative f16 default
    monkeypatch.setenv("OLLAMA_KV_CACHE_TYPE", "q8_0")
    assert model_scout.read_kv_factor() == 0.5
    monkeypatch.setenv("OLLAMA_KV_CACHE_TYPE", "q4_0")
    assert model_scout.read_kv_factor() == 0.25
    monkeypatch.setenv("OLLAMA_KV_CACHE_TYPE", "f16")
    assert model_scout.read_kv_factor() == 1.0


def _dense_9b() -> model_scout.Candidate:
    return model_scout.parse_model("Qwen/Qwen3.5-9B-GGUF")


def _candidate(
    *, total: float, active: float | None, is_moe: bool
) -> model_scout.Candidate:
    """A synthetic candidate, so a fit test states only the numbers it is about."""
    label = f"{total:g}B-A{active:g}B" if active else f"{total:g}B"
    return model_scout.Candidate(
        id=f"synthetic/{label}",
        author="synthetic",
        name=label,
        total=total,
        active=active,
        is_moe=is_moe,
        kind="general",
        reasoning=False,
        family="qwen",
        parse_warning=None,
    )


def test_category_fit_daily_driver_good_at_q8_32k() -> None:
    # The reference box: qwen3.5:9b q4 @32k on 12GB VRAM with q8_0 KV cache is
    # the known-good daily driver. weights 5.4 + KV 2.56 + 1.5 overhead = 9.46.
    fit = model_scout.category_fit(
        _dense_9b(),
        model_scout.Budget(ram_gb=32, vram_gb=12, disk_free_gb=100),
        ctx=32768,
        parallel=1,
        kv_factor=0.5,
    )
    assert fit.verdict == "Good"
    assert fit.weights_gb == 5.4
    assert fit.kv_gb == 2.56
    assert "32k" in fit.why


def test_category_fit_num_parallel_two_demotes_from_good() -> None:
    # NUM_PARALLEL=2 doubles KV (2.56 -> 5.12); demand 10.52 > 10.5 usable VRAM.
    fit = model_scout.category_fit(
        _dense_9b(),
        model_scout.Budget(ram_gb=32, vram_gb=12, disk_free_gb=100),
        ctx=32768,
        parallel=2,
        kv_factor=0.5,
    )
    assert fit.verdict != "Good"


def test_category_fit_f16_default_is_conservative_but_not_rejected() -> None:
    # With the conservative f16 default the daily driver sits at the boundary:
    # at-worst Tight (spills a little), never TooBig/Poor.
    fit = model_scout.category_fit(
        _dense_9b(),
        model_scout.Budget(ram_gb=32, vram_gb=12, disk_free_gb=100),
        ctx=32768,
        parallel=1,
        kv_factor=1.0,
    )
    assert fit.verdict in {"Good", "OK", "Tight"}


def test_category_fit_moe_rejected_when_weights_exceed_ram() -> None:
    # An 80B-A3B MoE has ~48GB of weights that must live in RAM+VRAM; on a 32GB
    # box it cannot load, MoE speed notwithstanding. (Regression: the MoE branch
    # must not bypass the RAM ceiling.)
    huge = model_scout.parse_model("unsloth/Qwen3-Next-80B-A3B-GGUF")
    assert huge.is_moe and huge.total == 80
    fit = model_scout.category_fit(
        huge,
        model_scout.Budget(ram_gb=32, vram_gb=12, disk_free_gb=200),
        ctx=8192,
        parallel=1,
        kv_factor=0.5,
    )
    assert fit.verdict == "TooBig"


def test_category_fit_moe_that_does_not_fit_vram_is_not_good() -> None:
    # A 35B-A3B is ~21GB of weights. It fits 32GB RAM, and its 3B active
    # parameters make CPU offload cheap - but it does NOT fit a 12GB card, so it
    # is "OK" (spills, tolerably), never "Good".
    #
    # This previously asserted "Good", which made "Good" mean two different
    # things: "resident in VRAM" on the dense path and "loads and runs
    # acceptably" on the MoE path. Both verdicts feed one comparable score, so
    # the scout ranked a model that could not fit above a dense model that
    # spilled exactly as far.
    moe = model_scout.parse_model("unsloth/Qwen3.6-35B-A3B-GGUF")
    fit = model_scout.category_fit(
        moe,
        model_scout.Budget(ram_gb=32, vram_gb=12, disk_free_gb=200),
        ctx=8192,
        parallel=1,
        kv_factor=0.5,
    )
    assert fit.verdict == "OK"
    assert fit.weights_gb + fit.kv_gb > 12 - model_scout.VRAM_OVERHEAD_GB
    assert "spills to CPU" in fit.why


def test_category_fit_moe_is_good_when_it_actually_fits_vram() -> None:
    # The other half of the contract: MoE is not penalised either. An 8B-A1B is
    # ~4.8GB of weights and genuinely fits a 12GB card, so it is "Good".
    moe = model_scout.parse_model("unsloth/Qwen3.6-8B-A1B-GGUF")
    assert moe.is_moe
    fit = model_scout.category_fit(
        moe,
        model_scout.Budget(ram_gb=32, vram_gb=12, disk_free_gb=200),
        ctx=8192,
        parallel=1,
        kv_factor=0.5,
    )
    assert fit.verdict == "Good"
    assert fit.weights_gb + fit.kv_gb <= 12 - model_scout.VRAM_OVERHEAD_GB


def test_category_fit_moe_and_dense_agree_on_whether_it_fits_vram() -> None:
    # Active parameters change compute per token, not the resident footprint.
    # Two models with the same weights must never disagree about fitting VRAM.
    budget = model_scout.Budget(ram_gb=32, vram_gb=12, disk_free_gb=200)
    fits = {"Good"}
    for total, active in ((30.0, 3.0), (8.0, 1.0)):
        moe = _candidate(total=total, active=active, is_moe=True)
        dense = _candidate(total=total, active=None, is_moe=False)
        moe_fit = model_scout.category_fit(
            moe, budget, ctx=16384, parallel=1, kv_factor=1.0
        )
        dense_fit = model_scout.category_fit(
            dense, budget, ctx=16384, parallel=1, kv_factor=1.0
        )
        assert moe_fit.weights_gb == dense_fit.weights_gb
        assert (moe_fit.verdict in fits) == (dense_fit.verdict in fits), (
            f"{total}B: MoE said {moe_fit.verdict}, dense said {dense_fit.verdict}"
        )


def test_category_fit_moe_still_outranks_dense_when_both_spill() -> None:
    # The real MoE advantage, preserved: when neither fits, the low-active model
    # reads far fewer weights per token, so it must still score higher.
    budget = model_scout.Budget(ram_gb=32, vram_gb=12, disk_free_gb=200)
    moe = _candidate(total=30.0, active=3.0, is_moe=True)
    dense = _candidate(total=30.0, active=None, is_moe=False)
    moe_fit = model_scout.category_fit(
        moe, budget, ctx=16384, parallel=1, kv_factor=1.0
    )
    dense_fit = model_scout.category_fit(
        dense, budget, ctx=16384, parallel=1, kv_factor=1.0
    )
    assert moe_fit.verdict == "OK"
    assert dense_fit.verdict == "Tight"
    moe_score = model_scout.score_candidate(
        replace(moe, verdict=moe_fit.verdict)
    ).score
    dense_score = model_scout.score_candidate(
        replace(dense, verdict=dense_fit.verdict)
    ).score
    assert moe_score > dense_score


def test_category_fit_moe_with_many_active_params_gets_no_offload_credit() -> None:
    # A high-active MoE offloads about as painfully as a dense model, so it does
    # not get the cheaper-spill verdict.
    budget = model_scout.Budget(ram_gb=32, vram_gb=12, disk_free_gb=200)
    chunky = _candidate(total=30.0, active=20.0, is_moe=True)
    fit = model_scout.category_fit(chunky, budget, ctx=16384, parallel=1, kv_factor=1.0)
    assert fit.verdict == "Tight"


def test_category_fit_reports_ctx_in_why_and_kv() -> None:
    fit = model_scout.category_fit(
        _dense_9b(),
        model_scout.Budget(ram_gb=32, vram_gb=12, disk_free_gb=100),
        ctx=8192,
        parallel=1,
        kv_factor=1.0,
    )
    # 8k KV for 9B f16 = 0.16*8 = 1.28 GB; must be surfaced honestly.
    assert fit.kv_gb == 1.28
    assert "8k" in fit.why


# ------------------------------------------------------- per-category scoring


def _built(model_id: str, **overrides: object) -> model_scout.Candidate:
    """A parsed candidate with downloads/age/family filled in for scoring."""
    base = model_scout.parse_model(model_id)
    defaults: dict[str, object] = {"downloads": 5000, "age_days": 10}
    return replace(base, **{**defaults, **overrides})


def _cat(category_id: str) -> scout_categories.Category:
    category = scout_categories.category_by_id(category_id)
    assert category is not None
    return category


_GOOD = model_scout.FitEstimate("Good", 8.4, 2.0, "fits")


def test_coder_model_gated_out_of_chat_but_eligible_for_coding() -> None:
    coder = _built("bartowski/Qwen2.5-Coder-14B-GGUF")
    assert coder.kind == "coder"
    assert not model_scout.candidate_eligible_for(coder, _cat("chat"))
    assert model_scout.candidate_eligible_for(coder, _cat("coding"))


def test_general_model_eligible_for_chat() -> None:
    general = _built("Qwen/Qwen3.5-9B-GGUF")
    assert general.kind == "general"
    assert model_scout.candidate_eligible_for(general, _cat("chat"))


def test_coder_kind_match_beats_general_in_coding() -> None:
    coding = _cat("coding")
    coder = _built("bartowski/Qwen2.5-Coder-14B-GGUF")
    general = _built("Qwen/Qwen3.5-14B-GGUF")
    assert general.kind == "general"
    coder_score = model_scout.score_for_category(coder, coding, _GOOD)
    general_score = model_scout.score_for_category(general, coding, _GOOD)
    assert coder_score > general_score


def test_web_nav_prefers_small_fast_over_big_thinker() -> None:
    web = _cat("web-nav")
    fast = _built("Qwen/Qwen3.5-4B-GGUF")
    thinker = _built("Qwen/Qwen3.5-14B-Thinking-GGUF")
    assert not fast.reasoning
    assert thinker.reasoning
    fast_score = model_scout.score_for_category(
        fast, web, model_scout.FitEstimate("Good", 2.4, 1.0, "fits")
    )
    thinker_score = model_scout.score_for_category(
        thinker, web, model_scout.FitEstimate("Good", 8.4, 2.0, "fits")
    )
    assert fast_score > thinker_score


def test_reasoning_helps_chat() -> None:
    chat = _cat("chat")
    thinker = _built("Qwen/Qwen3.5-9B-Thinking-GGUF")
    plain = _built("Qwen/Qwen3.5-9B-GGUF")
    assert thinker.reasoning and not plain.reasoning
    assert model_scout.score_for_category(
        thinker, chat, _GOOD
    ) > model_scout.score_for_category(plain, chat, _GOOD)


def test_score_reflects_fit_verdict() -> None:
    chat = _cat("chat")
    candidate = _built("Qwen/Qwen3.5-9B-GGUF")
    good = model_scout.score_for_category(candidate, chat, _GOOD)
    tight = model_scout.score_for_category(
        candidate, chat, model_scout.FitEstimate("Tight", 5.4, 8.0, "spills")
    )
    assert good > tight


# ---------------------------------------------------- grouped scout assembly


def _budget() -> model_scout.Budget:
    return model_scout.Budget(ram_gb=32, vram_gb=12, disk_free_gb=100)


def test_grouped_report_has_all_categories() -> None:
    groups = model_scout.collect_scout_groups(_budget(), [], parallel=1, kv_factor=0.5)
    assert set(groups) == {c.id for c in scout_categories.CATEGORIES}


def test_curated_seed_fills_empty_category() -> None:
    # No HF candidates at all: chat still recommends its curated seed.
    groups = model_scout.collect_scout_groups(_budget(), [], parallel=1, kv_factor=0.5)
    top = groups["chat"].top
    assert top is not None
    assert top.author == "curated"
    assert "9b" in top.name.lower()


def test_voice_category_empty_with_note() -> None:
    groups = model_scout.collect_scout_groups(_budget(), [], parallel=1, kv_factor=0.5)
    voice = groups["voice"]
    assert voice.top is None
    assert voice.runners_up == ()
    assert "Kokoro" in voice.why or "TTS" in voice.why


def test_real_candidate_beats_curated_seed_in_chat() -> None:
    hot = _built("Qwen/Qwen3.5-9B-GGUF", downloads=200000, age_days=3)
    groups = model_scout.collect_scout_groups(
        _budget(), [hot], parallel=1, kv_factor=0.5
    )
    top = groups["chat"].top
    assert top is not None
    assert top.author != "curated"


def test_vram_infeasible_candidate_lands_in_dropped_with_ctx_reason() -> None:
    # 43B dense: weights (~25.8GB) fit RAM, but KV@16k tips demand over budget,
    # so it is dropped as VRAM-infeasible with the context in the reason.
    huge = _built("Qwen/Qwen3.5-43B-GGUF", downloads=5000, age_days=5)
    groups = model_scout.collect_scout_groups(
        _budget(), [huge], parallel=1, kv_factor=0.5
    )
    dropped = dict(groups["chat"].dropped)
    name = next((n for n in dropped if "43B" in n), None)
    assert name is not None
    assert "16k" in dropped[name]


def test_coder_appears_in_coding_not_chat() -> None:
    coder = _built("bartowski/Qwen2.5-Coder-14B-GGUF", downloads=8000, age_days=5)
    groups = model_scout.collect_scout_groups(
        _budget(), [coder], parallel=1, kv_factor=0.5
    )
    coding = groups["coding"]
    picks = [c.name for c in (coding.top, *coding.runners_up) if c is not None]
    assert any("Coder" in name for name in picks)
    # Coder kind is not eligible for chat, so chat only has its curated seed.
    chat_top = groups["chat"].top
    assert chat_top is None or chat_top.author == "curated"


def test_groups_to_dict_is_json_serialisable() -> None:
    groups = model_scout.collect_scout_groups(
        _budget(), [_built("Qwen/Qwen3.5-9B-GGUF")], parallel=1, kv_factor=0.5
    )
    payload = model_scout.groups_to_dict(groups)
    json.dumps(payload)  # must not raise
    assert set(payload) == {c.id for c in scout_categories.CATEGORIES}
    assert payload["voice"]["top"] is None
    assert payload["chat"]["top"]["name"]


def test_write_scout_groups_writes_cache(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setattr(
        model_scout, "repo_path", lambda *parts: tmp_path.joinpath(*parts)
    )
    groups = model_scout.collect_scout_groups(_budget(), [], parallel=1, kv_factor=0.5)
    model_scout.write_scout_groups(groups, now=datetime(2026, 7, 8, 12, 0))
    cache = tmp_path / "logs" / "model-scout-groups.json"
    assert cache.exists()
    data = json.loads(cache.read_text(encoding="utf-8"))
    assert data["generated"].startswith("2026-07-08")
    assert set(data["groups"]) == {c.id for c in scout_categories.CATEGORIES}


def test_read_scout_groups_roundtrips(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setattr(
        model_scout, "repo_path", lambda *parts: tmp_path.joinpath(*parts)
    )
    assert model_scout.read_scout_groups() is None  # no cache yet
    groups = model_scout.collect_scout_groups(_budget(), [], parallel=1, kv_factor=0.5)
    model_scout.write_scout_groups(groups, now=datetime(2026, 7, 8, 12, 0))
    data = model_scout.read_scout_groups()
    assert data is not None
    assert data["generated"].startswith("2026-07-08")
    assert set(data["groups"]) == {c.id for c in scout_categories.CATEGORIES}


def test_fit_candidate_moe_does_not_claim_to_fit_vram_it_misses() -> None:
    # The discovery pass (apply_fit -> fit_candidate) ranks and de-duplicates
    # every candidate before the per-category pass runs, so the same residency
    # rule has to hold here: a 30B-A3B is ~18GB of weights and does not fit a
    # 12GB card, whatever its active parameter count.
    budget = model_scout.Budget(ram_gb=32, vram_gb=12, disk_free_gb=200)
    verdict, size, why = model_scout.fit_candidate(
        _candidate(total=30.0, active=3.0, is_moe=True), budget
    )
    assert verdict == "OK"
    assert size is not None and size > budget.vram_gb - model_scout.VRAM_OVERHEAD_GB
    assert "spills to CPU" in why


def test_fit_candidate_moe_is_good_when_it_fits() -> None:
    budget = model_scout.Budget(ram_gb=32, vram_gb=12, disk_free_gb=200)
    verdict, _size, why = model_scout.fit_candidate(
        _candidate(total=8.0, active=1.0, is_moe=True), budget
    )
    assert verdict == "Good"
    assert "fits fully" in why


def test_fit_candidate_moe_and_dense_agree_on_fitting_vram() -> None:
    budget = model_scout.Budget(ram_gb=32, vram_gb=12, disk_free_gb=200)
    for total, active in ((30.0, 3.0), (8.0, 1.0)):
        moe, _s, _w = model_scout.fit_candidate(
            _candidate(total=total, active=active, is_moe=True), budget
        )
        dense, _s2, _w2 = model_scout.fit_candidate(
            _candidate(total=total, active=None, is_moe=False), budget
        )
        assert (moe == "Good") == (dense == "Good"), f"{total}B: {moe} vs {dense}"


def test_fit_candidate_uses_the_named_budget_constants() -> None:
    # The literals in this function had drifted from the module constants, so
    # editing WEIGHTS_GB_PER_B silently changed nothing on the discovery path.
    budget = model_scout.Budget(ram_gb=32, vram_gb=12, disk_free_gb=200)
    _v, size, _w = model_scout.fit_candidate(
        _candidate(total=10.0, active=None, is_moe=False), budget
    )
    assert size == round(10.0 * model_scout.WEIGHTS_GB_PER_B, 1)


# ---------------------------------------- quant-aware resident weight sizing
#
# WEIGHTS_GB_PER_B is a single ~Q4_K_M bytes-per-parameter constant applied
# regardless of which quant is actually pulled. The HuggingFace tree response
# already carries the exact size of every file and select_quant_artefact keeps
# it, so the artefact that will really be downloaded can be priced as itself.


def test_exact_artefact_size_overrides_the_global_heuristic() -> None:
    # 8B at the heuristic is 4.8GB; the measured file says 5.03GB. The
    # measurement wins, and says so.
    sizing = model_scout.resolve_weight_sizing(
        total_b=8.0, quant="Q4_K_M", artefact_bytes=5_030_000_000
    )
    assert sizing is not None
    assert sizing.provenance == "measured-file"
    assert sizing.gb == 4.68  # 5.03e9 bytes in the binary GiB the budgets use
    assert sizing.gb != round(8.0 * model_scout.WEIGHTS_GB_PER_B, 1)


def test_q8_artefact_is_not_underpriced_as_though_it_were_q4() -> None:
    # best_quant falls back to `quants[0]`, which can be Q8_0. At 8 bits per
    # weight a 14B Q8_0 is ~14GB, not the ~8.4GB the Q4-shaped heuristic gives.
    # Under-pricing is the dangerous direction: it reports a fit that is absent.
    heuristic = 14.0 * model_scout.WEIGHTS_GB_PER_B
    sizing = model_scout.resolve_weight_sizing(total_b=14.0, quant="Q8_0")
    assert sizing is not None
    assert sizing.provenance == "bpw-table"
    assert sizing.gb > heuristic
    assert sizing.gb == round(14.0 * 8.0 / 8.0, 1)


def test_a_smaller_quant_never_shrinks_below_the_heuristic() -> None:
    # Q3_K's 3.4375 bpw would price a 14B at ~6GB, but K-quants keep embedding
    # and output tensors at higher precision, so the base figure understates the
    # real file. Missing evidence must not make a model look smaller.
    heuristic = round(14.0 * model_scout.WEIGHTS_GB_PER_B, 1)
    sizing = model_scout.resolve_weight_sizing(total_b=14.0, quant="Q3_K_M")
    assert sizing is not None
    assert sizing.gb == heuristic
    assert sizing.provenance == "global-heuristic"


def test_missing_size_and_unknown_quant_falls_back_to_the_estimator() -> None:
    sizing = model_scout.resolve_weight_sizing(total_b=9.0, quant="NOT_A_QUANT")
    assert sizing is not None
    assert sizing.provenance == "global-heuristic"
    assert sizing.gb == round(9.0 * model_scout.WEIGHTS_GB_PER_B, 1)
    # No parameter count and no measurement is genuinely unknown, not zero.
    assert model_scout.resolve_weight_sizing(total_b=None, quant="Q4_K_M") is None


def test_sizing_is_deterministic_for_identical_inputs() -> None:
    args = {"total_b": 12.0, "quant": "Q5_K_M", "artefact_bytes": None}
    first = model_scout.resolve_weight_sizing(**args)
    assert first == model_scout.resolve_weight_sizing(**args)


def test_resident_sizing_ignores_active_parameters_entirely() -> None:
    # A MoE loads every expert weight. resolve_weight_sizing takes no active
    # count by construction, so a 30B-A3B and a 30B dense of the same quant
    # must price identically.
    moe = model_scout.resolve_weight_sizing(total_b=30.0, quant="Q4_K_M")
    dense = model_scout.resolve_weight_sizing(total_b=30.0, quant="Q4_K_M")
    assert moe == dense
    # Enforced by construction: there is no active-parameter input to pass.
    params = set(inspect.signature(model_scout.resolve_weight_sizing).parameters)
    assert params == {"total_b", "quant", "artefact_bytes"}
    # And the same holds for a measured artefact.
    measured_moe = model_scout.resolve_weight_sizing(
        total_b=30.0, quant="Q4_K_M", artefact_bytes=18_560_000_000
    )
    measured_dense = model_scout.resolve_weight_sizing(
        total_b=30.0, quant="Q4_K_M", artefact_bytes=18_560_000_000
    )
    assert measured_moe == measured_dense == model_scout.WeightSizing(
        17.29, "Q4_K_M", "measured-file"
    )


def test_quant_bits_per_weight_handles_real_tags() -> None:
    bpw = model_scout.quant_bits_per_weight
    assert bpw("Q8_0") == 8.0
    assert bpw("Q4_K_M") == 4.5          # K-quant size class strips to the base
    assert bpw("Q4_K_S") == 4.5
    assert bpw("UD-Q4_K_XL") == 4.5      # Unsloth dynamic prefix
    assert bpw("IQ4_XS") == 4.25         # a whole name, not IQ4 + _XS
    assert bpw("IQ4_NL") == 4.5
    assert bpw("Q3_K_M") == 3.4375
    assert bpw("mystery") is None
    assert bpw(None) is None


# ---------------------------------------------- keeping the size already fetched


def _tree(*entries: tuple[str, int | None]) -> list[object]:
    rows: list[object] = []
    for path, size in entries:
        row: dict[str, object] = {"path": path, "type": "file"}
        if size is not None:
            row["size"] = size
        rows.append(row)
    return rows


def test_select_quant_artefact_keeps_the_exact_file_size(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        model_scout,
        "fetch_hf_tree",
        lambda repo: _tree(
            ("m-Q4_K_M.gguf", 5_030_000_000), ("m-Q8_0.gguf", 8_700_000_000)
        ),
    )
    artefact = model_scout.select_quant_artefact("x/y")
    assert artefact == model_scout.QuantArtefact("Q4_K_M", 5_030_000_000)
    # The back-compat wrapper still returns just the tag.
    assert model_scout.best_quant("x/y") == "Q4_K_M"


def test_select_quant_artefact_sums_shards(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        model_scout,
        "fetch_hf_tree",
        lambda repo: _tree(
            ("m-Q4_K_M-00001-of-00002.gguf", 10_000_000_000),
            ("m-Q4_K_M-00002-of-00002.gguf", 8_560_000_000),
        ),
    )
    artefact = model_scout.select_quant_artefact("x/y")
    assert artefact is not None
    assert artefact.size_bytes == 18_560_000_000


def test_select_quant_artefact_reports_no_size_when_a_shard_lacks_one(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Summing only the sized shards would under-count, which is the dangerous
    # direction, so the whole quant reports no size instead.
    monkeypatch.setattr(
        model_scout,
        "fetch_hf_tree",
        lambda repo: _tree(
            ("m-Q4_K_M-00001-of-00002.gguf", 10_000_000_000),
            ("m-Q4_K_M-00002-of-00002.gguf", None),
        ),
    )
    artefact = model_scout.select_quant_artefact("x/y")
    assert artefact is not None
    assert artefact.quant == "Q4_K_M"
    assert artefact.size_bytes is None


def test_select_quant_artefact_survives_an_api_failure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def boom(repo: str) -> list[object]:
        raise OSError("connection refused")

    monkeypatch.setattr(model_scout, "fetch_hf_tree", boom)
    assert model_scout.select_quant_artefact("x/y") is None
    assert model_scout.best_quant("x/y") is None


def _prepare_pick_pick() -> model_scout.Candidate:
    return model_scout.Candidate(
        id="unsloth/Big-30B-GGUF",
        author="unsloth",
        name="Big-30B",
        total=30.0,
        active=None,
        is_moe=False,
        kind="general",
        reasoning=False,
        family="qwen",
        parse_warning=None,
        verdict="Good",
        size_gb=18.0,
    )


def test_prepare_pick_refuses_a_measured_artefact_that_cannot_be_resident(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The scout ranked this at the ~18GB Q4 estimate. The repository actually
    # offers only Q8_0, and the measured artefact is 32GB - past the usable
    # memory on a 32GB box. Stop before the download, not at load time.
    monkeypatch.setattr(
        model_scout,
        "select_quant_artefact",
        lambda repo: model_scout.QuantArtefact("Q8_0", 32_000_000_000),
    )
    pulled: list[str] = []
    monkeypatch.setattr(
        model_scout,
        "pull_with_retry",
        lambda *a, **k: pulled.append("pulled")
        or CommandResult(("ollama",), 0, "", ""),
    )
    said: list[str] = []
    logged: list[str] = []
    code = model_scout.prepare_pick(
        _prepare_pick_pick(),
        budget=model_scout.Budget(ram_gb=32, vram_gb=12, disk_free_gb=500),
        state={"prepared": [], "seen": []},
        say=said.append,
        log=logged,
        no_pull=False,
        stream=False,
        now=datetime(2026, 8, 29, 12, 0),
        probe_timeout_sec=5,
    )

    assert code == 0
    assert pulled == []  # nothing downloaded
    assert any("Skipping pull" in line for line in said)
    assert any("29.8GB" in line for line in said)  # 32e9 bytes as GiB
    assert any("SKIPPED pull" in entry for entry in logged)


def test_prepare_pick_reports_the_measured_size_and_still_pulls_when_it_fits(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        model_scout,
        "select_quant_artefact",
        lambda repo: model_scout.QuantArtefact("Q4_K_M", 18_560_000_000),
    )
    monkeypatch.setattr(
        model_scout,
        "pull_with_retry",
        lambda *a, **k: CommandResult(("ollama",), 1, "", "no"),
    )
    said: list[str] = []
    model_scout.prepare_pick(
        _prepare_pick_pick(),
        budget=model_scout.Budget(ram_gb=32, vram_gb=12, disk_free_gb=500),
        state={"prepared": [], "seen": []},
        say=said.append,
        log=[],
        no_pull=False,
        stream=False,
        now=datetime(2026, 8, 29, 12, 0),
        probe_timeout_sec=5,
    )

    joined = " | ".join(said)
    assert "measured" in joined
    assert "17.3GB" in joined            # format_num renders to one decimal
    assert "scout estimated 18GB" in joined  # the estimate is shown alongside
    assert "Skipping pull" not in joined
    # The underlying figure keeps the full precision the API reported.
    assert model_scout.resolve_weight_sizing(
        total_b=30.0, quant="Q4_K_M", artefact_bytes=18_560_000_000
    ).gb == 17.29


def test_prepare_pick_low_disk_guard_runs_before_any_network_call(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # If there is already not enough disk, do not spend a request learning the
    # exact size. Also proves the guard's message is still the first line.
    def must_not_be_called(repo: str) -> None:
        raise AssertionError("select_quant_artefact called despite low disk")

    monkeypatch.setattr(model_scout, "select_quant_artefact", must_not_be_called)
    said: list[str] = []
    code = model_scout.prepare_pick(
        _prepare_pick_pick(),
        budget=model_scout.Budget(ram_gb=32, vram_gb=12, disk_free_gb=20),
        state={"prepared": [], "seen": []},
        say=said.append,
        log=[],
        no_pull=False,
        stream=False,
        now=datetime(2026, 8, 29, 12, 0),
        probe_timeout_sec=5,
    )
    assert code == 0
    assert said[0].startswith("[!] Low disk")


def test_discovery_makes_no_per_candidate_tree_request(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Exact sizing costs one HTTP request per REPO. Doing it during discovery
    # would mean one per candidate across five authors, so discovery stays on
    # the parameter-count estimate by design. This pins that.
    def must_not_be_called(repo: str) -> list[object]:
        raise AssertionError("fetch_hf_tree called during discovery")

    monkeypatch.setattr(model_scout, "fetch_hf_tree", must_not_be_called)
    monkeypatch.setattr(
        model_scout,
        "fetch_hf_models",
        lambda author: [
            {"id": f"{author}/Thing-8B-GGUF", "downloads": 10, "lastModified": ""}
        ],
    )
    rows = model_scout.discover_candidates(
        budget=model_scout.Budget(ram_gb=32, vram_gb=12, disk_free_gb=100),
        notes=[],
        now=datetime(2026, 8, 29, 12, 0),
    )
    assert rows  # discovery still works


# ------------------------------------------------------------------- units
#
# Every size in model_scout is compared against a hardware budget, and every
# budget is BINARY: nvidia-smi MiB / 1024, ullTotalPhys / 1024**3,
# disk_usage().free / 1024**3. Converting artefact bytes with 1e9 instead would
# make a measured size 7.4% larger than the budget it is checked against.


def test_measured_size_uses_the_same_binary_unit_as_the_budgets() -> None:
    one_gib = 1024**3
    sizing = model_scout.resolve_weight_sizing(
        total_b=8.0, quant="Q4_K_M", artefact_bytes=one_gib
    )
    assert sizing is not None
    assert sizing.gb == 1.0
    # A decimal conversion would report 1.07 for the same bytes.
    assert sizing.gb != round(one_gib / 1_000_000_000, 2)


def test_budget_probes_are_binary_so_the_comparison_is_like_for_like(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # VRAM: nvidia-smi reports MiB. A nominal 16GB card reports 16376 MiB, which
    # must land on 16.0 to stay in tier S - that is only true in binary units.
    result = model_scout.CommandResult(("nvidia-smi",), 0, "16376\n", "")
    monkeypatch.setattr(model_scout, "run_command", lambda *a, **k: result)
    assert model_scout.get_vram_gb(timeout_sec=5) == 16.0

    # RAM: 32 GiB of physical memory must read as 32.0, not 34.36.
    monkeypatch.setattr(
        model_scout, "get_total_physical_memory_bytes", lambda: 32 * 1024**3
    )
    assert model_scout.get_ram_gb(timeout_sec=5) == 32.0


def test_measured_size_and_ram_ceiling_agree_on_the_boundary() -> None:
    # The refusal in prepare_pick compares sizing.gb against ram_gb minus the
    # headroom. Both sides must be the same unit or the boundary is off by 7.4%.
    budget = model_scout.Budget(ram_gb=32.0, vram_gb=12.0, disk_free_gb=500.0)
    ram_ceil = budget.ram_gb - model_scout.RAM_HEADROOM_GB
    exactly_at_ceiling = int(ram_ceil * 1024**3)

    at = model_scout.resolve_weight_sizing(
        total_b=40.0, quant="Q4_K_M", artefact_bytes=exactly_at_ceiling
    )
    over = model_scout.resolve_weight_sizing(
        total_b=40.0, quant="Q4_K_M", artefact_bytes=exactly_at_ceiling + 2 * 1024**3
    )
    assert at is not None and over is not None
    assert at.gb <= ram_ceil
    assert over.gb > ram_ceil
