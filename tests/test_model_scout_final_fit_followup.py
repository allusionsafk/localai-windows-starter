from __future__ import annotations

import json
import os
from dataclasses import replace
from datetime import datetime
from pathlib import Path

import pytest

from localai import model_scout

_BUDGET = model_scout.Budget(ram_gb=32, vram_gb=12, disk_free_gb=500)
_SMALL_CONFIG = {
    "num_hidden_layers": 16,
    "num_key_value_heads": 2,
    "head_dim": 64,
    "max_position_embeddings": 32768,
}


def _candidate(
    repo: str,
    *,
    total: float = 12.0,
    downloads: int = 10_000,
    kind: str = "general",
) -> model_scout.Candidate:
    author, _, name = repo.partition("/")
    return model_scout.Candidate(
        id=repo,
        author=author,
        name=name.removesuffix("-GGUF"),
        total=total,
        active=None,
        is_moe=False,
        kind=kind,
        reasoning=False,
        family="qwen",
        parse_warning=None,
        downloads=downloads,
        age_days=1,
        modified="2026-08-31T00:00:00Z",
    )


def _measured_evidence(
    weight_gib: float = 5.0,
) -> model_scout.CandidateEvidence:
    return model_scout.CandidateEvidence(
        artefact=model_scout.QuantArtefact(
            "Q4_K_M", round(weight_gib * model_scout.GIB)
        ),
        weights=model_scout.WeightSizing(
            weight_gib, "Q4_K_M", "measured-file"
        ),
        architecture=model_scout.parse_architecture(_SMALL_CONFIG),
        runtime_support="unverified",
        runtime_provenance="no-positive-runtime-evidence",
    )


def _final_ranking(
    monkeypatch: pytest.MonkeyPatch,
    *,
    budget: model_scout.Budget = _BUDGET,
    parallel: int = 1,
    kv_factor: float = 0.5,
) -> model_scout.FinalRanking:
    candidate = _candidate("author/Cache-12B-GGUF")
    provisional = model_scout.collect_provisional_groups(
        budget, [candidate], parallel=parallel, kv_factor=kv_factor
    )
    monkeypatch.setattr(
        model_scout,
        "enrich_candidate",
        lambda _candidate: _measured_evidence(),
    )
    return model_scout.collect_final_groups(
        budget, provisional, parallel=parallel, kv_factor=kv_factor
    )


def _cache_path(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> Path:
    monkeypatch.setattr(
        model_scout, "repo_path", lambda *parts: tmp_path.joinpath(*parts)
    )
    return tmp_path / "logs" / "model-scout-groups.json"


def _matching_read_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        model_scout,
        "get_budget",
        lambda timeout_sec, vram_override=None: _BUDGET,
    )
    monkeypatch.setenv("OLLAMA_NUM_PARALLEL", "1")
    monkeypatch.setenv("OLLAMA_KV_CACHE_TYPE", "q8_0")


def _write_valid_cache(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> tuple[Path, model_scout.FinalRanking]:
    cache = _cache_path(monkeypatch, tmp_path)
    _matching_read_environment(monkeypatch)
    ranking = _final_ranking(monkeypatch)
    model_scout.write_scout_groups(
        ranking, now=datetime(2026, 9, 1, 9, 0)
    )
    return cache, ranking


def _first_serialized_candidate(payload: dict[str, object]) -> dict[str, object]:
    groups = payload["groups"]
    assert isinstance(groups, dict)
    for group in groups.values():
        assert isinstance(group, dict)
        top = group.get("top")
        if isinstance(top, dict):
            return top
    raise AssertionError("fixture did not serialize any candidate")


def test_real_discovery_preserves_same_name_repository_variants_and_reranks(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    bad_repo = "unsloth/Twin-12B-GGUF"
    good_repo = "bartowski/Twin-12B-GGUF"
    discovery_calls: list[str] = []

    def models(author: str) -> list[object]:
        discovery_calls.append(author)
        if author == "unsloth":
            return [
                {
                    "id": bad_repo,
                    "downloads": 1_000_000,
                    "lastModified": "2026-08-31T00:00:00Z",
                }
            ]
        if author == "bartowski":
            duplicate = {
                "id": good_repo,
                "downloads": 100,
                "lastModified": "2026-08-31T00:00:00Z",
            }
            return [duplicate, dict(duplicate)]
        return []

    tree_calls: list[str] = []
    config_calls: list[str] = []
    monkeypatch.setattr(model_scout, "fetch_hf_models", models)
    monkeypatch.setattr(
        model_scout,
        "select_quant_artefact",
        lambda repo: tree_calls.append(repo)
        or model_scout.QuantArtefact(
            "Q4_K_M",
            round((40.0 if repo == bad_repo else 5.0) * model_scout.GIB),
        ),
    )
    monkeypatch.setattr(
        model_scout,
        "fetch_hf_config",
        lambda repo: config_calls.append(repo) or _SMALL_CONFIG,
    )

    discovered = model_scout.discover_candidates(
        budget=_BUDGET,
        notes=[],
        now=datetime(2026, 9, 1, 9, 0),
    )

    assert len(discovery_calls) == len(model_scout.AUTHORS) == 5
    assert tree_calls == []
    assert [candidate.id for candidate in discovered].count(good_repo) == 1
    assert {candidate.id for candidate in discovered} == {bad_repo, good_repo}

    provisional = model_scout.collect_provisional_groups(
        _BUDGET, discovered, parallel=1, kv_factor=0.5
    )
    chat_repositories = {
        candidate.id
        for candidate in (
            provisional.groups["chat"].top,
            *provisional.groups["chat"].runners_up,
        )
        if candidate is not None and candidate.author != "curated"
    }
    assert chat_repositories == {bad_repo, good_repo}

    final = model_scout.collect_final_groups(
        _BUDGET, provisional, parallel=1, kv_factor=0.5
    )

    assert final.groups["chat"].top is not None
    assert final.groups["chat"].top.id == good_repo
    assert final.groups["chat"].top.verdict == "Good"
    assert final.groups["chat"].top.residency == "full-gpu"
    assert tree_calls.count(bad_repo) == tree_calls.count(good_repo) == 1
    assert config_calls.count(bad_repo) == config_calls.count(good_repo) == 1
    assert len(discovery_calls) + len(tree_calls) + len(config_calls) <= 41


def test_curated_seeds_do_not_consume_remote_finalist_slots(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    remotes = [
        _candidate(
            f"author/Coder-{index}-12B-GGUF",
            kind="coder",
            downloads=30 - index,
        )
        for index in range(3)
    ]
    provisional = model_scout.collect_provisional_groups(
        _BUDGET, remotes, parallel=1, kv_factor=0.5
    )

    coding = provisional.groups["coding"]
    shortlisted = {
        candidate.id
        for candidate in (coding.top, *coding.runners_up)
        if candidate is not None
    }

    assert shortlisted == {candidate.id for candidate in remotes}
    assert all(not repo.startswith("curated/") for repo in shortlisted)
    assert all(
        candidate.author != "curated"
        for result in provisional.groups.values()
        for candidate in (result.top, *result.runners_up)
        if candidate is not None
    )


def test_real_discovery_pipeline_proves_exact_41_request_ceiling(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    repositories = [f"unsloth/Bound-{index}-1B-GGUF" for index in range(18)]
    discovery_calls: list[str] = []

    def models(author: str) -> list[object]:
        discovery_calls.append(author)
        if author != "unsloth":
            return []
        rows = [
            {
                "id": repo,
                "downloads": 100,
                "lastModified": "2026-08-31T00:00:00Z",
            }
            for repo in repositories
        ]
        return [*rows, dict(rows[0])]

    category_positions = {
        category.id: index for index, category in enumerate(model_scout.CATEGORIES)
    }
    monkeypatch.setattr(model_scout, "fetch_hf_models", models)
    monkeypatch.setattr(
        model_scout, "candidate_eligible_for", lambda _candidate, _category: True
    )
    monkeypatch.setattr(
        model_scout,
        "score_for_category",
        lambda candidate, category, _fit: (
            -1000.0
            if candidate.id not in repositories
            else (
                1000.0 - repositories.index(candidate.id) % 3
                if category_positions[category.id] * 3
                <= repositories.index(candidate.id)
                < category_positions[category.id] * 3 + 3
                else 0.0
            )
        ),
    )
    metadata_calls: list[tuple[str, str]] = []
    monkeypatch.setattr(
        model_scout,
        "select_quant_artefact",
        lambda repo: metadata_calls.append(("tree", repo))
        or model_scout.QuantArtefact("Q4_K_M", model_scout.GIB),
    )
    monkeypatch.setattr(
        model_scout,
        "fetch_hf_config",
        lambda repo: metadata_calls.append(("config", repo)) or _SMALL_CONFIG,
    )

    discovered = model_scout.discover_candidates(
        budget=_BUDGET,
        notes=[],
        now=datetime(2026, 9, 1, 9, 0),
    )
    provisional = model_scout.collect_provisional_groups(
        _BUDGET, discovered, parallel=1, kv_factor=0.5
    )
    finalists = model_scout.select_bounded_finalists(provisional)

    assert len(discovery_calls) == 5
    assert metadata_calls == []
    assert len(discovered) == len(repositories)
    assert len(finalists) == model_scout.MAX_ENRICHED_FINALISTS == 18

    model_scout.collect_final_groups(
        _BUDGET, provisional, parallel=1, kv_factor=0.5
    )

    assert len(metadata_calls) == 36
    assert len(discovery_calls) + len(metadata_calls) == 41
    assert all(
        sum(repo == candidate_repo for _kind, repo in metadata_calls) == 2
        for candidate_repo in repositories
    )


@pytest.mark.parametrize(
    ("tensor_type", "minimum_gib"),
    [("FP8", 12.0), ("BF16", 24.0), ("F16", 24.0)],
)
def test_unsized_wide_tensor_uses_conservative_type_width(
    tensor_type: str,
    minimum_gib: float,
) -> None:
    sizing = model_scout.resolve_weight_sizing(
        total_b=12.0,
        quant=tensor_type,
        artefact_bytes=None,
    )

    assert sizing is not None
    assert sizing.gb is not None and sizing.gb >= minimum_gib
    assert sizing.provenance.startswith("bpw-table")


@pytest.mark.parametrize("tensor_type", ["MXFP4", "NVFP4"])
def test_unsized_low_precision_non_q_uses_defined_type_width(
    tensor_type: str,
) -> None:
    sizing = model_scout.resolve_weight_sizing(
        total_b=12.0,
        quant=tensor_type,
        artefact_bytes=None,
    )

    assert sizing is not None
    assert sizing.gb is not None and sizing.gb >= 7.2
    assert sizing.provenance.startswith("bpw-table")


def test_unsized_fp8_cannot_be_underpriced_into_final_good(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    candidate = _candidate("author/Unsized-FP8-12B-GGUF")
    provisional = model_scout.collect_provisional_groups(
        _BUDGET, [candidate], parallel=1, kv_factor=0.5
    )
    monkeypatch.setattr(
        model_scout,
        "enrich_candidate",
        lambda _candidate: model_scout.CandidateEvidence(
            artefact=model_scout.QuantArtefact("FP8", None),
            weights=model_scout.resolve_weight_sizing(total_b=12.0, quant="FP8"),
            architecture=model_scout.parse_architecture(_SMALL_CONFIG),
            runtime_support="unverified",
            runtime_provenance="no-positive-runtime-evidence",
        ),
    )

    final = model_scout.collect_final_groups(
        _BUDGET, provisional, parallel=1, kv_factor=0.5
    )
    picks = [
        pick
        for pick in (
            final.groups["chat"].top,
            *final.groups["chat"].runners_up,
        )
        if pick is not None and pick.id == candidate.id
    ]

    assert picks
    assert picks[0].verdict != "Good"
    assert picks[0].residency != "full-gpu"


def test_parseable_tensor_without_safe_width_stays_unverified() -> None:
    sizing = model_scout.resolve_weight_sizing(
        total_b=12.0,
        quant="Q9_MYSTERY",
        artefact_bytes=None,
    )

    assert sizing is not None
    assert sizing.gb is None
    assert sizing.provenance == "unverified-tensor-width"


def test_final_fit_cache_has_explicit_schema_and_fit_context(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    cache, _ranking = _write_valid_cache(monkeypatch, tmp_path)
    payload = json.loads(cache.read_text(encoding="utf-8"))

    assert payload["schemaVersion"] == model_scout.SCOUT_CACHE_SCHEMA_VERSION
    assert payload["fitStage"] == "final"
    assert payload["fitContext"]["vramGb"] == _BUDGET.vram_gb
    assert payload["fitContext"]["ramGb"] == _BUDGET.ram_gb
    assert payload["fitContext"]["parallel"] == 1
    assert payload["fitContext"]["kvFactor"] == 0.5
    assert payload["fitContextFingerprint"]
    assert "hostname" not in payload["fitContext"]
    assert "path" not in payload["fitContext"]


def test_marker_only_cache_is_rejected(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    cache = _cache_path(monkeypatch, tmp_path)
    _matching_read_environment(monkeypatch)
    cache.parent.mkdir(parents=True)
    cache.write_text('{"fitStage":"final"}', encoding="utf-8")

    assert model_scout.read_scout_groups() is None


def test_candidate_level_provisional_cache_is_rejected(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    cache, _ranking = _write_valid_cache(monkeypatch, tmp_path)
    payload = json.loads(cache.read_text(encoding="utf-8"))
    _first_serialized_candidate(payload)["fitStage"] = "provisional"
    cache.write_text(json.dumps(payload), encoding="utf-8")

    assert model_scout.read_scout_groups() is None


def test_partial_category_cache_is_rejected(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    cache, _ranking = _write_valid_cache(monkeypatch, tmp_path)
    payload = json.loads(cache.read_text(encoding="utf-8"))
    del payload["groups"]["voice"]
    cache.write_text(json.dumps(payload), encoding="utf-8")

    assert model_scout.read_scout_groups() is None


def test_unknown_cache_schema_is_rejected(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    cache, _ranking = _write_valid_cache(monkeypatch, tmp_path)
    payload = json.loads(cache.read_text(encoding="utf-8"))
    payload["schemaVersion"] = 999
    cache.write_text(json.dumps(payload), encoding="utf-8")

    assert model_scout.read_scout_groups() is None


@pytest.mark.parametrize(
    ("field", "bad_value"),
    [
        ("verdict", "Possibly"),
        ("residency", "teleport"),
        ("fitConfidence", "certain-ish"),
        ("runtimeSupport", "maybe"),
        ("weightProvenance", "guessed"),
        ("kvProvenance", "guessed"),
    ],
)
def test_malformed_final_candidate_cache_is_rejected(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    field: str,
    bad_value: str,
) -> None:
    cache, _ranking = _write_valid_cache(monkeypatch, tmp_path)
    payload = json.loads(cache.read_text(encoding="utf-8"))
    _first_serialized_candidate(payload)[field] = bad_value
    cache.write_text(json.dumps(payload), encoding="utf-8")

    assert model_scout.read_scout_groups() is None


def test_unhashable_cache_enum_is_rejected_without_raising(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    cache, _ranking = _write_valid_cache(monkeypatch, tmp_path)
    payload = json.loads(cache.read_text(encoding="utf-8"))
    _first_serialized_candidate(payload)["residency"] = []
    cache.write_text(json.dumps(payload), encoding="utf-8")

    assert model_scout.read_scout_groups() is None


def test_incomplete_serialized_candidate_is_rejected(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    cache, _ranking = _write_valid_cache(monkeypatch, tmp_path)
    payload = json.loads(cache.read_text(encoding="utf-8"))
    candidate = _first_serialized_candidate(payload)
    candidate.pop("sizeGb")
    candidate.pop("tensorType")
    cache.write_text(json.dumps(payload), encoding="utf-8")

    assert model_scout.read_scout_groups() is None


@pytest.mark.parametrize(
    "updates",
    [
        {"verdict": "Good", "residency": "full-gpu", "runtimeSupport": "unsupported"},
        {
            "verdict": "Unsupported",
            "residency": "full-gpu",
            "runtimeSupport": "supported",
        },
        {"verdict": "Tight", "residency": "full-gpu", "runtimeSupport": "unverified"},
    ],
)
def test_semantically_impossible_cached_candidate_is_rejected(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    updates: dict[str, object],
) -> None:
    cache, _ranking = _write_valid_cache(monkeypatch, tmp_path)
    payload = json.loads(cache.read_text(encoding="utf-8"))
    _first_serialized_candidate(payload).update(updates)
    cache.write_text(json.dumps(payload), encoding="utf-8")

    assert model_scout.read_scout_groups() is None


@pytest.mark.parametrize("shape", ["runner-without-top", "too-many", "unsorted"])
def test_invalid_cached_group_candidate_shape_is_rejected(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    shape: str,
) -> None:
    cache, _ranking = _write_valid_cache(monkeypatch, tmp_path)
    payload = json.loads(cache.read_text(encoding="utf-8"))
    group = next(
        value
        for value in payload["groups"].values()
        if isinstance(value, dict) and isinstance(value.get("top"), dict)
    )
    candidate = dict(group["top"])
    if shape == "runner-without-top":
        group["top"] = None
        group["runnersUp"] = [candidate]
    elif shape == "too-many":
        group["runnersUp"] = [dict(candidate) for _ in range(3)]
    else:
        runner = dict(candidate)
        runner["id"] = "author/Higher-Runner-12B-GGUF"
        runner["score"] = float(candidate["score"]) + 1.0
        group["runnersUp"] = [runner]
    cache.write_text(json.dumps(payload), encoding="utf-8")

    assert model_scout.read_scout_groups() is None


def test_malformed_cached_dropped_entry_is_rejected(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    cache, _ranking = _write_valid_cache(monkeypatch, tmp_path)
    payload = json.loads(cache.read_text(encoding="utf-8"))
    next(iter(payload["groups"].values()))["dropped"] = ["not-an-object"]
    cache.write_text(json.dumps(payload), encoding="utf-8")

    assert model_scout.read_scout_groups() is None


def test_cache_from_different_vram_budget_is_rejected(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    _cache, _ranking = _write_valid_cache(monkeypatch, tmp_path)
    monkeypatch.setattr(
        model_scout,
        "get_budget",
        lambda timeout_sec, vram_override=None: replace(_BUDGET, vram_gb=16),
    )

    assert model_scout.read_scout_groups() is None


def test_cache_from_different_category_context_is_rejected(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    _cache, _ranking = _write_valid_cache(monkeypatch, tmp_path)
    monkeypatch.setattr(
        model_scout,
        "CATEGORIES",
        tuple(
            replace(category, target_ctx=category.target_ctx + 1024)
            if category.id == "chat"
            else category
            for category in model_scout.CATEGORIES
        ),
    )

    assert model_scout.read_scout_groups() is None


def test_cache_from_different_parallelism_is_rejected(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    _cache, _ranking = _write_valid_cache(monkeypatch, tmp_path)
    monkeypatch.setenv("OLLAMA_NUM_PARALLEL", "2")

    assert model_scout.read_scout_groups() is None


def test_cache_from_different_kv_factor_is_rejected(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    _cache, _ranking = _write_valid_cache(monkeypatch, tmp_path)
    monkeypatch.setenv("OLLAMA_KV_CACHE_TYPE", "f16")

    assert model_scout.read_scout_groups() is None


def test_matching_complete_final_cache_is_accepted(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    _cache, _ranking = _write_valid_cache(monkeypatch, tmp_path)

    payload = model_scout.read_scout_groups()

    assert payload is not None
    assert payload["schemaVersion"] == model_scout.SCOUT_CACHE_SCHEMA_VERSION
    assert set(payload["groups"]) == {
        category.id for category in model_scout.CATEGORIES
    }


def test_legacy_and_truncated_caches_are_rejected(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    cache = _cache_path(monkeypatch, tmp_path)
    _matching_read_environment(monkeypatch)
    cache.parent.mkdir(parents=True)
    cache.write_text(
        json.dumps({"generated": "old", "groups": {}}), encoding="utf-8"
    )
    assert model_scout.read_scout_groups() is None

    cache.write_text('{"schemaVersion":', encoding="utf-8")
    assert model_scout.read_scout_groups() is None


def test_interrupted_atomic_cache_write_keeps_previous_valid_cache(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    cache, ranking = _write_valid_cache(monkeypatch, tmp_path)
    original = cache.read_text(encoding="utf-8")

    def interrupted_replace(_source: object, _destination: object) -> None:
        raise OSError("simulated interruption before atomic replace")

    monkeypatch.setattr(os, "replace", interrupted_replace)

    with pytest.raises(OSError, match="simulated interruption"):
        model_scout.write_scout_groups(
            ranking, now=datetime(2026, 9, 1, 9, 1)
        )

    assert cache.read_text(encoding="utf-8") == original
    assert list(cache.parent.glob("*.tmp")) == []


def test_old_final_boolean_bypass_is_removed() -> None:
    with pytest.raises(TypeError):
        model_scout.collect_scout_groups(
            _BUDGET,
            [_candidate("author/Raw-12B-GGUF")],
            parallel=1,
            kv_factor=0.5,
            final=True,
        )


def test_raw_provisional_groups_cannot_construct_final_ranking() -> None:
    provisional = model_scout.collect_provisional_groups(
        _BUDGET,
        [_candidate("author/Raw-12B-GGUF")],
        parallel=1,
        kv_factor=0.5,
    )

    with pytest.raises(ValueError, match="finalization evidence"):
        model_scout.FinalRanking(provisional.groups)


def test_final_stage_string_without_finalist_evidence_is_rejected() -> None:
    provisional = model_scout.collect_provisional_groups(
        _BUDGET,
        [_candidate("author/Raw-12B-GGUF")],
        parallel=1,
        kv_factor=0.5,
    )
    relabelled: dict[str, model_scout.CategoryResult] = {}
    for category_id, result in provisional.groups.items():
        top = replace(result.top, fit_stage="final") if result.top else None
        runners = tuple(
            replace(runner, fit_stage="final") for runner in result.runners_up
        )
        relabelled[category_id] = replace(result, top=top, runners_up=runners)

    with pytest.raises(ValueError, match="finalization evidence"):
        model_scout.FinalRanking(relabelled)


def test_valid_remote_enrichment_constructs_final_ranking(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    final = _final_ranking(monkeypatch)
    top = final.groups["chat"].top

    assert top is not None
    assert isinstance(top.evidence, model_scout.RemoteFinalistEvidence)
    assert top.evidence.repository_id == top.id
    assert model_scout.groups_to_dict(final)["chat"]["top"]["fitStage"] == "final"


def test_empty_remote_evidence_cannot_construct_final_fit() -> None:
    candidate = _candidate("author/Empty-Evidence-12B-GGUF")
    with pytest.raises(ValueError, match="weight sizing"):
        model_scout.FinalizedCandidate(
            candidate,
            model_scout.RemoteFinalistEvidence(
                candidate.id,
                model_scout.CandidateEvidence(None, None, None),
            ),
        )


def test_curated_seed_uses_explicit_static_finalization_evidence(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    provisional = model_scout.collect_provisional_groups(
        _BUDGET, [], parallel=1, kv_factor=0.5
    )
    final = model_scout.collect_final_groups(
        _BUDGET, provisional, parallel=1, kv_factor=0.5
    )
    top = final.groups["chat"].top

    assert top is not None and top.author == "curated"
    assert isinstance(top.evidence, model_scout.CuratedFinalistEvidence)
    assert top.evidence.repository_id == top.id
    assert top.evidence.resolved.weights is not None
    assert top.evidence.resolved.weights.gb is not None


def test_curated_seed_without_static_sizing_is_not_promoted_to_final_ok() -> None:
    provisional = model_scout.collect_provisional_groups(
        _BUDGET, [], parallel=1, kv_factor=0.5
    )

    final = model_scout.collect_final_groups(
        _BUDGET, provisional, parallel=1, kv_factor=0.5
    )

    assert final.groups["embedding"].top is None
    assert all(
        candidate.id != "curated/nomic-embed-text"
        for result in final.groups.values()
        for candidate in (result.top, *result.runners_up)
        if candidate is not None
    )


def test_markdown_log_rejects_provisional_ranking(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    _cache_path(monkeypatch, tmp_path)
    provisional = model_scout.collect_provisional_groups(
        _BUDGET,
        [_candidate("author/Raw-12B-GGUF")],
        parallel=1,
        kv_factor=0.5,
    )

    with pytest.raises(ValueError, match="final"):
        model_scout.write_model_scout_log(
            mode="Scout",
            now=datetime(2026, 9, 1, 9, 0),
            ranking=provisional,
            pick=None,
            notes=[],
        )
