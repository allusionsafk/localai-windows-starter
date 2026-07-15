"""Behavioral tests for perf.py loaded-model VRAM breakdown."""
from localai import perf


def _fake_api(payloads):
    def fake(path, timeout_sec=10):
        return payloads[path]
    return fake


def test_loaded_models_reports_weights_kv_and_cpu_split(monkeypatch):
    monkeypatch.setattr(
        perf, "ollama_api",
        _fake_api({
            "/api/ps": {"models": [{
                "name": "qwen3.5:9b-32k",
                "size": 10200547328,       # ~9.5 GB loaded footprint
                "size_vram": 9341747200,   # ~8.7 GB on GPU
                "context_length": 32768,
            }]},
            "/api/tags": {"models": [{
                "name": "qwen3.5:9b-32k",
                "size": 6227702579,        # ~5.8 GB weights on disk
            }]},
        }),
    )
    lines = []
    perf.test_loaded_models(lambda status, label, detail: lines.append((status, label, detail)))
    assert len(lines) == 1
    status, label, detail = lines[0]
    assert label == "qwen3.5:9b-32k residency"
    assert "weights 5.8 GB" in detail
    assert "ctx/KV+overhead 3.7 GB" in detail
    assert "CPU side 0.8 GB" in detail
    assert "num_ctx 32768" in detail


def test_loaded_models_survives_missing_tags(monkeypatch):
    monkeypatch.setattr(
        perf, "ollama_api",
        _fake_api({
            "/api/ps": {"models": [{"name": "m", "size": 2.0 * 1024**3, "size_vram": 2.0 * 1024**3}]},
            "/api/tags": {"models": []},
        }),
    )
    lines = []
    perf.test_loaded_models(lambda s, l, d: lines.append(d))
    assert len(lines) == 1
    assert "weights" not in lines[0]  # no disk size -> no fake breakdown
    assert "% GPU" in lines[0]
