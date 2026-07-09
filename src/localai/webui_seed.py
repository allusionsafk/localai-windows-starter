"""Seed Open WebUI's SQLite config from the installer.

Open WebUI persists its config in ``webui.db`` (constraint #3): after first boot,
compose env vars are ignored, so per-model params and key/value config must be
written to the DB. The DB lives in a named docker volume, reachable only through
the container, so the write runs as a ``python -c`` snippet via
``docker compose exec`` -- the same pattern ``health.check_open_webui_thinking``
uses to read it.

To keep the shipped in-container code identical to what the tests exercise, the
DB logic lives in plain functions over a ``sqlite3.Connection`` (unit-tested on
in-memory fixtures) and the snippet is *generated from their source*
(``inspect.getsource``) -- there is no hand-copied fork to drift. The functions
below therefore use only ``json`` + ``sqlite3`` and take no localai imports.
"""

from __future__ import annotations

import inspect
import json
import sqlite3
from collections.abc import Callable
from datetime import UTC, datetime
from typing import Any

from localai import compose

CONTAINER_DB_URI = "file:/app/backend/data/webui.db"


class SeedSchemaError(Exception):
    """Open WebUI DB is not the expected key/value config + model(id,params) shape."""


def qwen_thinking_params(num_ctx: int) -> dict[str, Any]:
    """Per-model params for a Qwen thinking model (constraint #4).

    ``presence_penalty`` is an API/DB param only -- never a Modelfile PARAMETER --
    so it must be seeded here rather than baked into the tag.
    """
    return {"think": False, "num_ctx": num_ctx, "presence_penalty": 1.5}


# --------------------------------------------------------------------------
# Everything from here to ``seed`` is embedded verbatim into the in-container
# snippet by build_snippet(). Keep it self-contained: json + sqlite3 only.
# --------------------------------------------------------------------------


def probe_schema(con: sqlite3.Connection) -> str:
    """Classify the DB: 'ok' (key/value config + model), 'legacy' (old id/data
    blob), or 'unsupported'. Guards a write against a schema drift (audit #2)."""
    tables = {
        r[0]
        for r in con.execute(
            "select name from sqlite_master where type='table'"
        ).fetchall()
    }
    if "model" not in tables or "config" not in tables:
        return "unsupported"
    model_cols = {r[1] for r in con.execute("pragma table_info(model)").fetchall()}
    if not {"id", "params"} <= model_cols:
        return "unsupported"
    config_cols = {r[1] for r in con.execute("pragma table_info(config)").fetchall()}
    if {"key", "value"} <= config_cols:
        return "ok"
    if {"id", "data"} <= config_cols:
        return "legacy"
    return "unsupported"


def apply_config(con: sqlite3.Connection, key: str, value: str, now: str) -> str:
    """Upsert one key/value config row, bumping updated_at."""
    con.execute(
        "INSERT INTO config (key, value, updated_at) VALUES (?, ?, ?) "
        "ON CONFLICT(key) DO UPDATE SET value=excluded.value, "
        "updated_at=excluded.updated_at",
        (key, value, now),
    )
    return f"config '{key}' seeded"


def apply_model_params(
    con: sqlite3.Connection, model_id: str, params: dict[str, Any], now: str
) -> str:
    """Merge ``params`` into an existing model row's params JSON.

    UPDATE-only: a missing row is reported and skipped rather than INSERTed, so a
    partial write can never corrupt Open WebUI's model table (warm the model
    first -- ``localai start`` registers the row)."""
    del now
    row = con.execute(
        "select params from model where id=?", (model_id,)
    ).fetchone()
    if row is None:
        return f"skip: model row '{model_id}' absent (warm it first)"
    existing = json.loads(row[0] or "{}")
    existing.update(params)
    merged = json.dumps(existing, sort_keys=True)
    con.execute("update model set params=? where id=?", (merged, model_id))
    return f"model '{model_id}' params seeded"


def seed(con: sqlite3.Connection, spec: dict[str, Any], now: str) -> list[str]:
    """Apply a seed spec {'config': {...}, 'models': {id: params}} idempotently.

    Raises SeedSchemaError (mapped to exit 2) unless the DB is the expected
    key/value schema, so a drift refuses loudly instead of corrupting data."""
    state = probe_schema(con)
    if state != "ok":
        raise SeedSchemaError("unsupported Open WebUI schema: " + state)
    applied: list[str] = []
    for key, value in (spec.get("config") or {}).items():
        applied.append(apply_config(con, key, value, now))
    for model_id, params in (spec.get("models") or {}).items():
        applied.append(apply_model_params(con, model_id, params, now))
    con.commit()
    return applied


# --------------------------------------------------------------------------


def build_snippet(spec: dict[str, Any], *, now: str) -> str:
    """Generate the self-contained program that runs inside the open-webui
    container. Embeds the very functions above so shipped == tested."""
    embedded = (SeedSchemaError, probe_schema, apply_config, apply_model_params, seed)
    sources = "\n\n\n".join(inspect.getsource(obj).rstrip() for obj in embedded)
    # ``json.dumps(json.dumps(...))`` yields a Python-source string literal of the
    # JSON payload -- valid because every JSON string is a valid Python literal.
    default_uri = json.dumps(CONTAINER_DB_URI)
    now_literal = json.dumps(now)
    spec_literal = json.dumps(json.dumps(spec))
    driver = "\n".join(
        [
            f"DB_URI = sys.argv[1] if len(sys.argv) > 1 else {default_uri}",
            f"NOW = {now_literal}",
            f"SPEC = json.loads({spec_literal})",
            "IS_URI = DB_URI.startswith('file:')",
            "try:",
            "    con = sqlite3.connect(DB_URI, uri=IS_URI, timeout=4)",
            "except sqlite3.OperationalError as exc:",
            "    print('OPEN: ' + str(exc))",
            "    sys.exit(3)",
            "con.execute('PRAGMA busy_timeout=4000')",
            "try:",
            "    applied = seed(con, SPEC, NOW)",
            "except SeedSchemaError as exc:",
            "    print('SCHEMA: ' + str(exc))",
            "    con.close()",
            "    sys.exit(2)",
            "con.close()",
            r"print('\n'.join(applied))",
            "sys.exit(0)",
        ]
    )
    # The embedded functions carry real annotations (sqlite3.Connection, Any);
    # in-container they are evaluated eagerly, so the snippet must import them.
    preamble = "import json\nimport sqlite3\nimport sys\nfrom typing import Any"
    return f"{preamble}\n\n\n{sources}\n\n\n{driver}\n"


def collect_webui_seed_report(
    *,
    model: str | None = None,
    num_ctx: int = 32768,
    default_model: str | None = None,
    dry_run: bool = False,
    timeout_sec: int = 30,
    service: str = "open-webui",
    now: str | None = None,
    exec_fn: Callable[..., Any] | None = None,
) -> tuple[int, list[str]]:
    """Seed Open WebUI config for the installer's chosen models.

    Builds a spec (Qwen thinking params for ``model`` + optional default-model
    config), then runs the generated snippet in the container. ``--dry-run``
    prints the snippet without touching the DB.
    """
    spec: dict[str, Any] = {"config": {}, "models": {}}
    if model:
        spec["models"][model] = qwen_thinking_params(num_ctx)
    if default_model:
        spec["config"]["ui.default_models"] = default_model
    if not spec["models"] and not spec["config"]:
        return 2, ["[!] webui-seed: nothing to seed (pass --model or --default-model)"]

    stamp = now or datetime.now(UTC).isoformat()
    snippet = build_snippet(spec, now=stamp)

    if dry_run:
        return 0, [
            "[dry-run] webui-seed would exec this in the open-webui container:",
            snippet,
        ]

    runner = exec_fn or compose.compose_exec
    result = runner(service, ["python", "-c", snippet], timeout_sec=timeout_sec)
    text = result.text.strip()
    if result.code == 0:
        return 0, [f"[ok] Open WebUI seeded: {text}"]
    if result.code == 2:
        return 2, [
            f"[!] Open WebUI schema unsupported; refused to write ({text}). "
            "See bd localai-flr.32/.35."
        ]
    if result.code == 3:
        return 3, [f"[!] Open WebUI DB unavailable; is the container up? ({text})"]
    return result.code, [f"[!] webui-seed failed ({result.code}): {text}"]
