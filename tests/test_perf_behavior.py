"""Behavioral tests for perf.py loaded-model VRAM breakdown."""
from localai import perf


def _fake_api(payloads):
    def fake(path, timeout_sec=10):
        return payloads[path]
    return fake


class _FakeResult:
    def __init__(self, code, text):
        self.code = code
        self.text = text


def _fake_smi(used_mib):
    def fake(cmd, cwd=None, timeout_sec=15):
        assert cmd[0] == "nvidia-smi"
        return _FakeResult(0, f"{used_mib}\n")
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
    # GPU reports 11.2 GiB used -> ~2.5 GiB beyond Ollama-attributed 8.7 GiB.
    monkeypatch.setattr(perf, "run_command", _fake_smi(11469))
    lines = []
    perf.test_loaded_models(lambda status, label, detail: lines.append((status, label, detail)))
    assert len(lines) == 2
    status, label, detail = lines[0]
    assert label == "qwen3.5:9b-32k residency"
    assert "weights 5.8 GB" in detail
    # /api/ps size excludes KV cache (measured 2026-07-15), so size - disk is
    # labelled plain "overhead" and KV shows up in the gap line instead.
    assert "overhead 3.7 GB" in detail
    assert "CPU side 0.8 GB" in detail
    assert "num_ctx 32768" in detail
    kv_status, kv_label, kv_detail = lines[1]
    assert kv_label == "Context/KV cache"
    assert "~2.5 GB GPU beyond Ollama-attributed" in kv_detail


def test_loaded_models_survives_missing_tags_and_smi(monkeypatch):
    monkeypatch.setattr(
        perf, "ollama_api",
        _fake_api({
            "/api/ps": {"models": [{"name": "m", "size": 2.0 * 1024**3, "size_vram": 2.0 * 1024**3}]},
            "/api/tags": {"models": []},
        }),
    )
    # nvidia-smi absent (AMD/CPU box) -> no KV gap line, no crash.
    monkeypatch.setattr(
        perf, "run_command", lambda cmd, cwd=None, timeout_sec=15: _FakeResult(1, "")
    )
    lines = []
    perf.test_loaded_models(lambda s, l, d: lines.append(d))
    assert len(lines) == 1
    assert "weights" not in lines[0]  # no disk size -> no fake breakdown
    assert "% GPU" in lines[0]
