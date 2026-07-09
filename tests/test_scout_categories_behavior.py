from __future__ import annotations

from localai import scout_categories


def test_categories_are_exactly_the_brief_set() -> None:
    ids = {category.id for category in scout_categories.CATEGORIES}
    assert ids == {"chat", "coding", "vision", "web-nav", "embedding", "voice"}


def test_category_ids_are_unique_and_stable_order() -> None:
    ids = [category.id for category in scout_categories.CATEGORIES]
    assert len(ids) == len(set(ids))
    # Chat is the primary daily-driver category and leads the list.
    assert ids[0] == "chat"


def test_every_category_is_well_formed() -> None:
    for category in scout_categories.CATEGORIES:
        assert category.label
        assert category.kinds, f"{category.id} has no eligible kinds"
        assert category.target_ctx > 0
        assert isinstance(category.curated, tuple)
        axes = {axis for axis, _weight in category.weights}
        assert axes, f"{category.id} has no scoring weights"
        unknown = axes - scout_categories.SCORE_AXES
        assert not unknown, f"{category.id} references unknown axis: {unknown}"


def test_category_by_id_lookup() -> None:
    coding = scout_categories.category_by_id("coding")
    assert coding is not None
    assert coding.label == "Coding"
    assert scout_categories.category_by_id("nonexistent") is None


def test_coding_targets_full_context() -> None:
    # Constraint #2: a coding daily driver runs at 32k; the category's ctx is the
    # contract that flows into KV fit and the prepared Modelfile's num_ctx.
    coding = scout_categories.category_by_id("coding")
    assert coding is not None
    assert coding.target_ctx == 32768
    assert "coder" in coding.kinds


def test_web_nav_penalises_reasoning() -> None:
    # This repo built a whole proxy to suppress thinking during navigation, so a
    # reasoning model is a negative for web-nav.
    web_nav = scout_categories.category_by_id("web-nav")
    assert web_nav is not None
    assert scout_categories.weight_of(web_nav, "reasoning") < 0
    assert scout_categories.weight_of(web_nav, "speed") > 0


def test_voice_category_carries_an_honest_note() -> None:
    voice = scout_categories.category_by_id("voice")
    assert voice is not None
    # Stack voice is Kokoro TTS + Whisper (Docker/CPU), not an Ollama GGUF.
    assert voice.note
    assert voice.curated == ()


def test_weight_of_defaults_to_zero_for_absent_axis() -> None:
    chat = scout_categories.category_by_id("chat")
    assert chat is not None
    assert scout_categories.weight_of(chat, "speed") >= 0  # present or absent -> >=0
    assert scout_categories.weight_of(chat, "not-an-axis") == 0.0
