from __future__ import annotations

import json
from dataclasses import replace
from datetime import datetime
from pathlib import Path

import pytest

from localai import model_scout

_BUDGET = model_scout.Budget(ram_gb=32, vram_gb=12, disk_free_gb=500)
_SMALL_KV = model_scout.ArchitectureInfo(
    n_layer=16, n_head_kv=2, head_dim=64, native_context=32768
)
_LARGE_KV = model_scout.ArchitectureInfo(
    n_layer=48, n_head_kv=16, head_dim=128, native_context=32768
)


def _candidate(
    repo: str,
    *,
    total: float = 9.0,
    active: float | None = None,
    is_moe: bool = False,
    kind: str = "general",
    downloads: int = 10_000,
) -> model_scout.Candidate:
    author, _, name = repo.partition("/")
    return model_scout.Candidate(
        id=repo,
        author=author,
        name=name.removesuffix("-GGUF"),
        total=total,
        active=active,
        is_moe=is_moe,
        kind=kind,
        reasoning=False,
        family="qwen",
        parse_warning=None,
        downloads=downloads,
        age_days=5,
        modified="2026-08-30T00:00:00Z",
    )


def _evidence(
    *,
    weight_gib: float,
    arch: model_scout.ArchitectureInfo | None = _SMALL_KV,
    runtime_support: str = "unverified",
    runtime_provenance: str = "no-positive-runtime-evidence",
):
    size_bytes = round(weight_gib * model_scout.GIB)
    artefact = model_scout.QuantArtefact("Q4_K_M", size_bytes)
    return model_scout.CandidateEvidence(
        artefact=artefact,
        weights=model_scout.WeightSizing(weight_gib, "Q4_K_M", "measured-file"),
        architecture=arch,
        runtime_support=runtime_support,
        runtime_provenance=runtime_provenance,
    )


def _final_fit(candidate: model_scout.Candidate, evidence) -> model_scout.FitEstimate:
    return model_scout.category_fit(
        candidate,
        _BUDGET,
        ctx=16384,
        parallel=1,
        kv_factor=0.5,
        evidence=evidence,
        final=True,
    )


def test_exact_artefact_downgrades_provisional_good_that_spills() -> None:
    candidate = _candidate("author/Model-9B-GGUF")
    provisional = model_scout.category_fit(
        candidate, _BUDGET, ctx=16384, parallel=1, kv_factor=0.5
    )
    assert provisional.verdict == "Good"

    final = _final_fit(candidate, _evidence(weight_gib=11.0))

    assert final.verdict != "Good"
    assert final.residency != "full-gpu"
    assert final.stage == "final"
    assert final.weight_provenance == "measured-file"


def test_host_ram_loadability_is_not_full_gpu_fit() -> None:
    candidate = _candidate("author/Host-Loadable-9B-GGUF")

    final = _final_fit(candidate, _evidence(weight_gib=14.0))

    assert final.verdict == "Tight"
    assert final.residency == "host-loadable"
    assert final.weights_gb < _BUDGET.ram_gb - model_scout.RAM_HEADROOM_GB
    assert final.weights_gb > _BUDGET.vram_gb - model_scout.VRAM_OVERHEAD_GB


def test_exact_artefact_and_kv_rerank_equal_provisional_candidates(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    provisional_first = _candidate("author/First-9B-GGUF")
    eventual_winner = _candidate("author/Second-9B-GGUF")
    provisional = model_scout.collect_provisional_groups(
        _BUDGET,
        [provisional_first, eventual_winner],
        parallel=1,
        kv_factor=0.5,
    )
    assert provisional.groups["chat"].top.id == provisional_first.id

    evidence = {
        provisional_first.id: _evidence(weight_gib=9.0, arch=_LARGE_KV),
        eventual_winner.id: _evidence(weight_gib=8.0, arch=_SMALL_KV),
    }
    monkeypatch.setattr(
        model_scout, "enrich_candidate", lambda candidate: evidence[candidate.id]
    )

    final = model_scout.collect_final_groups(
        _BUDGET, provisional, parallel=1, kv_factor=0.5
    )

    assert final.groups["chat"].top.id == eventual_winner.id
    assert final.groups["chat"].top.fit_stage == "final"
    assert final.groups["chat"].top.verdict == "Good"
    assert final.groups["chat"].runners_up[0].verdict != "Good"


def test_lower_provisional_candidate_can_become_final_winner(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    popular = _candidate("author/Popular-9B-GGUF", downloads=1_000_000)
    less_popular = _candidate("author/Accurate-9B-GGUF", downloads=1_000)
    provisional = model_scout.collect_provisional_groups(
        _BUDGET, [popular, less_popular], parallel=1, kv_factor=0.5
    )
    assert provisional.groups["chat"].top.id == popular.id

    evidence = {
        popular.id: _evidence(weight_gib=15.0, arch=_LARGE_KV),
        less_popular.id: _evidence(weight_gib=7.0, arch=_SMALL_KV),
    }
    monkeypatch.setattr(
        model_scout, "enrich_candidate", lambda candidate: evidence[candidate.id]
    )

    final = model_scout.collect_final_groups(
        _BUDGET, provisional, parallel=1, kv_factor=0.5
    )

    assert final.groups["chat"].top.id == less_popular.id


def test_active_moe_params_never_shrink_final_residency() -> None:
    low_active = _candidate(
        "author/MoE-Low-30B-A3B-GGUF", total=30, active=3, is_moe=True
    )
    high_active = replace(low_active, id="author/MoE-High-30B-A20B-GGUF", active=20)
    evidence = _evidence(weight_gib=17.0)

    low = _final_fit(low_active, evidence)
    high = _final_fit(high_active, evidence)

    assert low.weights_gb == high.weights_gb == 17.0
    assert low.residency == high.residency
    assert low.verdict == "OK"  # compute/spill credit only
    assert high.verdict == "Tight"


def test_missing_exact_metadata_stays_fallback_and_runtime_unverified(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(model_scout, "select_quant_artefact", lambda _repo: None)
    monkeypatch.setattr(model_scout, "fetch_hf_config", lambda _repo: None)

    evidence = model_scout.enrich_candidate(_candidate("author/Fallback-9B-GGUF"))

    assert evidence.weights is not None
    assert evidence.weights.provenance == "global-heuristic"
    assert evidence.architecture is None
    assert evidence.runtime_support == "unverified"
    fit = _final_fit(_candidate("author/Fallback-9B-GGUF"), evidence)
    assert fit.confidence == "fallback"
    assert fit.kv_provenance == "param-buckets"


def _ranking_with_repositories(repositories: list[str]):
    groups: dict[str, model_scout.CategoryResult] = {}
    cursor = 0
    for category in model_scout.CATEGORIES:
        picks = [
            _candidate(repositories[(cursor + offset) % len(repositories)])
            for offset in range(3)
        ]
        cursor += 3
        groups[category.id] = model_scout.CategoryResult(
            category.id,
            picks[0],
            tuple(picks[1:]),
            "provisional",
            (),
        )
    return model_scout.ProvisionalRanking(groups)


def test_enrichment_is_bounded_to_top_three_per_six_categories(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    repositories = [f"author/Model-{index}-9B-GGUF" for index in range(30)]
    provisional = _ranking_with_repositories(repositories)
    calls: list[tuple[str, str]] = []
    monkeypatch.setattr(
        model_scout,
        "select_quant_artefact",
        lambda repo: calls.append(("tree", repo))
        or model_scout.QuantArtefact("Q4_K_M", 5 * model_scout.GIB),
    )
    monkeypatch.setattr(
        model_scout,
        "fetch_hf_config",
        lambda repo: calls.append(("config", repo)) or None,
    )

    finalists = model_scout.enrich_finalists(
        model_scout.select_bounded_finalists(provisional)
    )

    assert len(finalists) == 18
    assert len(calls) == 36
    assert len({repo for _kind, repo in calls}) == 18


def test_duplicate_finalist_repositories_are_enriched_once(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    provisional = _ranking_with_repositories(
        ["author/Shared-9B-GGUF", "author/Other-9B-GGUF"]
    )
    calls: list[tuple[str, str]] = []
    monkeypatch.setattr(
        model_scout,
        "select_quant_artefact",
        lambda repo: calls.append(("tree", repo))
        or model_scout.QuantArtefact("Q4_K_M", 5 * model_scout.GIB),
    )
    monkeypatch.setattr(
        model_scout,
        "fetch_hf_config",
        lambda repo: calls.append(("config", repo)) or None,
    )

    finalists = model_scout.enrich_finalists(
        model_scout.select_bounded_finalists(provisional)
    )

    assert len(finalists) == 2
    assert calls.count(("tree", "author/Shared-9B-GGUF")) == 1
    assert calls.count(("config", "author/Shared-9B-GGUF")) == 1


def test_prepare_pick_reuses_attached_evidence_without_refetching(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    evidence = _evidence(weight_gib=30.0)
    pick = replace(
        _candidate("author/Too-Large-9B-GGUF"),
        evidence=evidence,
        fit_stage="final",
    )

    def forbidden(_repo: str):
        raise AssertionError("prepare_pick refetched resolved finalist evidence")

    monkeypatch.setattr(model_scout, "select_quant_artefact", forbidden)
    monkeypatch.setattr(model_scout, "fetch_hf_config", forbidden)
    said: list[str] = []

    code = model_scout.prepare_pick(
        pick,
        budget=_BUDGET,
        state={"prepared": [], "seen": []},
        say=said.append,
        log=[],
        no_pull=True,
        stream=False,
        now=datetime(2026, 8, 31, 12, 0),
        probe_timeout_sec=1,
        num_ctx=16384,
    )

    assert code == 0
    assert any("Skipping pull" in line for line in said)


def test_unsupported_requires_positive_evidence() -> None:
    candidate = _candidate("author/Runtime-Unknown-9B-GGUF")
    missing = _final_fit(candidate, _evidence(weight_gib=5.0))
    positive = _final_fit(
        candidate,
        _evidence(
            weight_gib=5.0,
            runtime_support="unsupported",
            runtime_provenance="installed-runtime-rejected-architecture",
        ),
    )

    assert missing.runtime_support == "unverified"
    assert missing.verdict != "Unsupported"
    assert positive.runtime_support == "unsupported"
    assert positive.verdict == "Unsupported"
    assert positive.residency == "unsupported"


def test_quant_origin_is_not_guessed_from_tensor_type(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        model_scout,
        "select_quant_artefact",
        lambda _repo: model_scout.QuantArtefact("Q4_0", 5 * model_scout.GIB),
    )
    monkeypatch.setattr(model_scout, "fetch_hf_config", lambda _repo: None)

    evidence = model_scout.enrich_candidate(_candidate("author/QAT-Looking-9B-GGUF"))

    assert evidence.artefact is not None
    assert evidence.artefact.quant == "Q4_0"
    assert evidence.artefact.quant_origin == "unverified"


@pytest.mark.parametrize("tensor_type", ["MXFP4", "NVFP4", "FP8", "BF16", "F16"])
def test_selected_artefact_keeps_relevant_non_q_tensor_types(
    monkeypatch: pytest.MonkeyPatch,
    tensor_type: str,
) -> None:
    monkeypatch.setattr(
        model_scout,
        "fetch_hf_tree",
        lambda _repo: [
            {
                "path": f"Model-9B-{tensor_type}.gguf",
                "size": 7 * model_scout.GIB,
                "type": "file",
            }
        ],
    )

    artefact = model_scout.select_quant_artefact("author/Model-9B-GGUF")

    assert artefact is not None
    assert artefact.quant == tensor_type
    assert artefact.size_bytes == 7 * model_scout.GIB
    assert artefact.quant_origin == "unverified"


def test_public_json_rejects_provisional_ranking_and_exposes_final_provenance(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    candidate = _candidate("author/Serializable-9B-GGUF")
    provisional = model_scout.collect_provisional_groups(
        _BUDGET, [candidate], parallel=1, kv_factor=0.5
    )
    with pytest.raises(ValueError, match="provisional"):
        model_scout.groups_to_dict(provisional)

    monkeypatch.setattr(
        model_scout, "enrich_candidate", lambda _candidate: _evidence(weight_gib=5.0)
    )
    final = model_scout.collect_final_groups(
        _BUDGET, provisional, parallel=1, kv_factor=0.5
    )
    payload = model_scout.groups_to_dict(final)
    top = payload["chat"]["top"]

    assert top["fitStage"] == "final"
    assert top["residency"] == "full-gpu"
    assert top["weightProvenance"] == "measured-file"
    assert top["runtimeSupport"] == "unverified"


def test_cli_pick_line_exposes_final_confidence_and_runtime_status() -> None:
    pick = replace(
        _candidate("author/Visible-Evidence-9B-GGUF"),
        verdict="Good",
        size_gb=6.0,
        score=200.0,
        fit_stage="final",
        fit_confidence="fallback",
        residency="full-gpu",
        runtime_support="unverified",
    )
    lines: list[str] = []

    model_scout._say_pick(lines.append, "TOP ", pick)

    assert "final/fallback" in lines[0]
    assert "runtime unverified" in lines[0]


def test_legacy_cache_without_final_stage_marker_is_rejected(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    monkeypatch.setattr(
        model_scout, "repo_path", lambda *parts: tmp_path.joinpath(*parts)
    )
    cache = tmp_path / "logs" / "model-scout-groups.json"
    cache.parent.mkdir(parents=True)
    cache.write_text(
        json.dumps(
            {
                "generated": "2026-08-30 12:00",
                "groups": {
                    "chat": {"top": {"name": "old", "verdict": "Good"}}
                },
            }
        ),
        encoding="utf-8",
    )

    assert model_scout.read_scout_groups() is None


def test_mixed_tensor_filename_selects_preferred_quant_token(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        model_scout,
        "fetch_hf_tree",
        lambda _repo: [
            {
                "path": "Model-FP8-Q4_K_M.gguf",
                "size": 7 * model_scout.GIB,
                "type": "file",
            }
        ],
    )

    artefact = model_scout.select_quant_artefact("author/Model-GGUF")

    assert artefact is not None
    assert artefact.quant == "Q4_K_M"
    assert artefact.size_bytes == 7 * model_scout.GIB


def test_malformed_tree_metadata_falls_back_instead_of_aborting(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def malformed(_repo: str):
        raise ValueError("malformed tree JSON")

    monkeypatch.setattr(model_scout, "fetch_hf_tree", malformed)

    assert model_scout.select_quant_artefact("author/Model-GGUF") is None


def test_final_wrapper_cannot_relabel_provisional_candidates() -> None:
    provisional = model_scout.collect_provisional_groups(
        _BUDGET, [_candidate("author/Model-9B-GGUF")], parallel=1, kv_factor=0.5
    )
    falsely_wrapped = model_scout.FinalRanking(provisional.groups)

    with pytest.raises(ValueError, match="final-stage"):
        model_scout.groups_to_dict(falsely_wrapped)


def test_markdown_log_exposes_final_provenance(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    monkeypatch.setattr(
        model_scout, "repo_path", lambda *parts: tmp_path.joinpath(*parts)
    )
    candidate = replace(
        _candidate("author/Logged-9B-GGUF"),
        verdict="Good",
        size_gb=6.0,
        score=200.0,
        fit_stage="final",
        fit_confidence="fallback",
        residency="full-gpu",
        weight_provenance="global-heuristic",
        kv_provenance="param-buckets",
        runtime_support="unverified",
    )
    groups = {
        category.id: model_scout.CategoryResult(
            category.id,
            candidate if category.id == "chat" else None,
            (),
            "test",
            (),
        )
        for category in model_scout.CATEGORIES
    }

    model_scout.write_model_scout_log(
        mode="Scout",
        now=datetime(2026, 8, 31, 12, 0),
        groups=groups,
        pick=None,
        notes=[],
    )

    log = (tmp_path / "logs" / "model-scout-log.md").read_text(encoding="utf-8")
    assert "stage:final/fallback" in log
    assert "weights:global-heuristic" in log
    assert "kv:param-buckets" in log
    assert "runtime:unverified" in log
