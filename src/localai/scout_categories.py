"""Task categories for the per-function model scout.

Data-driven on purpose: every category is a row in :data:`CATEGORIES`, and the
scout/CLI/dashboard iterate that tuple - adding a category is a data edit, not a
code change. Each row says which model ``kind``s are eligible (see
``model_scout.model_kind``), the context length that task actually needs (which
drives the KV-cache VRAM fit and the prepared Modelfile's ``num_ctx``), how to
weight the scoring axes for that task, known-good curated seeds for days the
HuggingFace feed is sparse, and an honest caveat.
"""

from __future__ import annotations

from dataclasses import dataclass

# Scoring axes a category may weight. Kept as the single source of truth so a
# typo in a weight table is caught by a test rather than silently ignored.
SCORE_AXES: frozenset[str] = frozenset(
    {
        "fit",  # VRAM verdict at the category's target ctx
        "popularity",  # HF downloads (log-scaled)
        "freshness",  # recently released
        "speed",  # small effective params = faster tokens/first-response
        "kind_match",  # exact model_kind beats a general-purpose fallback
        "family",  # known, well-supported family
        "reasoning",  # thinking models (a plus for chat/coding, a minus for web-nav)
    }
)

Weights = tuple[tuple[str, float], ...]


@dataclass(frozen=True)
class Category:
    """One task category the scout recommends a best pick for."""

    id: str
    label: str
    kinds: tuple[str, ...]
    target_ctx: int
    weights: Weights
    curated: tuple[str, ...] = ()
    note: str = ""


CATEGORIES: tuple[Category, ...] = (
    Category(
        id="chat",
        label="Chat",
        kinds=("general",),
        target_ctx=16384,
        weights=(
            ("fit", 1.0),
            ("popularity", 0.5),
            ("freshness", 0.4),
            ("family", 0.3),
            ("reasoning", 0.3),
            ("kind_match", 0.2),
        ),
        curated=("qwen3.5:9b-32k",),
    ),
    Category(
        id="coding",
        label="Coding",
        kinds=("coder", "general"),
        target_ctx=32768,
        weights=(
            ("fit", 1.0),
            ("kind_match", 0.8),
            ("popularity", 0.4),
            ("family", 0.3),
            ("reasoning", 0.3),
            ("speed", 0.2),
        ),
        curated=("qwen3-coder:30b", "qwen2.5-coder:14b"),
    ),
    Category(
        id="vision",
        label="Vision",
        kinds=("vision",),
        target_ctx=8192,
        weights=(
            ("kind_match", 1.0),
            ("fit", 0.8),
            ("popularity", 0.4),
            ("freshness", 0.3),
        ),
        curated=("qwen2.5vl:7b",),
    ),
    Category(
        id="web-nav",
        label="Web Nav",
        kinds=("general", "coder"),
        target_ctx=16384,
        weights=(
            ("speed", 1.0),
            ("fit", 0.7),
            ("kind_match", 0.4),
            ("family", 0.3),
            ("reasoning", -0.5),  # thinking slows navigation; this repo proxies it off
        ),
        curated=("web-nav-qwen3.5-9b", "qwen2.5-coder:14b"),
        note=(
            "Point Nanobrowser at the think-proxy (localhost:11435); "
            "thinking is suppressed."
        ),
    ),
    Category(
        id="embedding",
        label="Embedding",
        kinds=("embed",),
        target_ctx=2048,
        weights=(
            ("speed", 0.8),
            ("popularity", 0.6),
            ("fit", 0.5),
        ),
        curated=("nomic-embed-text",),
        note=(
            "Open WebUI runs file-RAG embeddings on CPU by default "
            "(RAG_EMBEDDING_ENGINE unset)."
        ),
    ),
    Category(
        id="voice",
        label="Voice",
        kinds=("audio",),
        target_ctx=4096,
        weights=(
            ("popularity", 0.6),
            ("fit", 0.5),
            ("freshness", 0.3),
        ),
        curated=(),
        note=(
            "Stack voice is Kokoro TTS + Whisper STT (Docker, CPU) - "
            "not an Ollama GGUF."
        ),
    ),
)


def category_by_id(category_id: str) -> Category | None:
    """The category with this id, or None."""
    return next((c for c in CATEGORIES if c.id == category_id), None)


def weight_of(category: Category, axis: str) -> float:
    """This category's weight for ``axis`` (0.0 if it does not weight it)."""
    return next((weight for name, weight in category.weights if name == axis), 0.0)
