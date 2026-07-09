from __future__ import annotations

import json
import sqlite3
import subprocess
import sys

import pytest

from localai import webui_seed

NOW = "2026-07-09T12:00:00Z"
LATER = "2026-07-09T13:30:00Z"

_CONFIG_DDL = "CREATE TABLE config (key TEXT PRIMARY KEY, value TEXT, updated_at TEXT)"
_MODEL_DDL = "CREATE TABLE model (id TEXT PRIMARY KEY, params TEXT)"


def _raw_params(con: sqlite3.Connection, model_id: str) -> str:
    return con.execute(
        "select params from model where id=?", (model_id,)
    ).fetchone()[0]


def _new_schema_db() -> sqlite3.Connection:
    """Open WebUI's current key/value config schema (constraint #3)."""
    con = sqlite3.connect(":memory:")
    con.execute(_CONFIG_DDL)
    con.execute(_MODEL_DDL)
    return con


def _legacy_schema_db() -> sqlite3.Connection:
    """The old single-row config(id,data) blob the thinklight script still assumes."""
    con = sqlite3.connect(":memory:")
    con.execute("CREATE TABLE config (id INTEGER PRIMARY KEY, data TEXT)")
    con.execute(_MODEL_DDL)
    return con


# ---------------------------------------------------------------- schema probe


def test_probe_recognizes_key_value_schema() -> None:
    assert webui_seed.probe_schema(_new_schema_db()) == "ok"


def test_probe_flags_legacy_blob_schema() -> None:
    assert webui_seed.probe_schema(_legacy_schema_db()) == "legacy"


def test_probe_flags_missing_model_table() -> None:
    con = sqlite3.connect(":memory:")
    con.execute("CREATE TABLE config (key TEXT, value TEXT, updated_at TEXT)")
    assert webui_seed.probe_schema(con) == "unsupported"


# ----------------------------------------------------------- qwen param preset


def test_qwen_thinking_params_carry_constraint_4_values() -> None:
    # constraint #4: presence_penalty 1.5 + think off; num_ctx matches the pick.
    assert webui_seed.qwen_thinking_params(32768) == {
        "think": False,
        "num_ctx": 32768,
        "presence_penalty": 1.5,
    }


# --------------------------------------------------------------- seed behavior


def test_seed_writes_model_params_json_on_existing_row() -> None:
    con = _new_schema_db()
    con.execute("INSERT INTO model (id, params) VALUES ('qwen3.5:9b-32k', '{}')")
    spec = {"models": {"qwen3.5:9b-32k": webui_seed.qwen_thinking_params(32768)}}

    webui_seed.seed(con, spec, now=NOW)

    row = con.execute(
        "select params from model where id='qwen3.5:9b-32k'"
    ).fetchone()
    params = json.loads(row[0])
    assert params["think"] is False
    assert params["num_ctx"] == 32768
    assert params["presence_penalty"] == 1.5


def test_seed_merges_without_clobbering_existing_params() -> None:
    con = _new_schema_db()
    con.execute(
        "INSERT INTO model (id, params) VALUES "
        "('m', '{\"temperature\": 1.0}')"
    )
    webui_seed.seed(con, {"models": {"m": {"think": False}}}, now=NOW)

    params = json.loads(_raw_params(con, "m"))
    assert params["temperature"] == 1.0  # preserved
    assert params["think"] is False  # added


def test_seed_skips_missing_model_row_without_inserting() -> None:
    con = _new_schema_db()
    result = webui_seed.seed(con, {"models": {"ghost": {"think": False}}}, now=NOW)

    # No phantom row inserted (avoids corrupting Open WebUI's model table).
    assert con.execute("select count(*) from model").fetchone()[0] == 0
    assert any("ghost" in line and "skip" in line.lower() for line in result)


def test_seed_writes_config_key_value_rows() -> None:
    con = _new_schema_db()
    webui_seed.seed(con, {"config": {"ui.default_models": "qwen3.5:9b-32k"}}, now=NOW)

    row = con.execute(
        "select value, updated_at from config where key='ui.default_models'"
    ).fetchone()
    assert row[0] == "qwen3.5:9b-32k"
    assert row[1] == NOW


def test_seed_is_idempotent_and_bumps_updated_at() -> None:
    con = _new_schema_db()
    con.execute("INSERT INTO model (id, params) VALUES ('m', '{}')")
    spec = {
        "config": {"k": "v"},
        "models": {"m": {"think": False}},
    }
    webui_seed.seed(con, spec, now=NOW)
    first_params = _raw_params(con, "m")

    webui_seed.seed(con, spec, now=LATER)

    # Same number of rows, identical params bytes, updated_at advanced.
    assert con.execute("select count(*) from config").fetchone()[0] == 1
    assert _raw_params(con, "m") == first_params  # byte-identical, idempotent
    updated = con.execute(
        "select updated_at from config where key='k'"
    ).fetchone()[0]
    assert updated == LATER


def test_seed_refuses_legacy_schema_loudly() -> None:
    with pytest.raises(webui_seed.SeedSchemaError):
        webui_seed.seed(_legacy_schema_db(), {"config": {"k": "v"}}, now=NOW)


# ------------------------------------------- in-container snippet (no drift)


def test_snippet_embeds_the_real_seed_logic() -> None:
    snippet = webui_seed.build_snippet({"config": {"k": "v"}}, now=NOW)
    # The shipped snippet must contain the very functions the unit tests exercise,
    # not a hand-copied fork that can silently drift from the tested logic.
    assert "def seed(" in snippet
    assert "def probe_schema(" in snippet
    assert "def apply_model_params(" in snippet


def test_generated_snippet_runs_against_a_real_sqlite_db(tmp_path) -> None:
    db = tmp_path / "webui.db"
    con = sqlite3.connect(db)
    con.execute(_CONFIG_DDL)
    con.execute(_MODEL_DDL)
    con.execute("INSERT INTO model (id, params) VALUES ('m', '{}')")
    con.commit()
    con.close()

    spec = {
        "config": {"k": "v"},
        "models": {"m": webui_seed.qwen_thinking_params(8192)},
    }
    script = tmp_path / "seed.py"
    script.write_text(webui_seed.build_snippet(spec, now=NOW), encoding="utf-8")

    proc = subprocess.run(
        [sys.executable, str(script), str(db)],
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0, proc.stdout + proc.stderr

    con = sqlite3.connect(db)
    params = json.loads(_raw_params(con, "m"))
    assert params["num_ctx"] == 8192
    assert con.execute("select value from config where key='k'").fetchone()[0] == "v"
    con.close()


def test_generated_snippet_exits_2_on_legacy_schema(tmp_path) -> None:
    db = tmp_path / "webui.db"
    con = sqlite3.connect(db)
    con.execute("CREATE TABLE config (id INTEGER PRIMARY KEY, data TEXT)")
    con.execute(_MODEL_DDL)
    con.commit()
    con.close()

    script = tmp_path / "seed.py"
    snippet = webui_seed.build_snippet({"config": {"k": "v"}}, now=NOW)
    script.write_text(snippet, encoding="utf-8")
    proc = subprocess.run(
        [sys.executable, str(script), str(db)],
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 2  # unsupported/legacy schema, refused


def test_cli_webui_seed_command_registered() -> None:
    from localai import cli

    callbacks = {
        info.callback.__name__ for info in cli.app.registered_commands if info.callback
    }
    assert "webui_seed" in callbacks
