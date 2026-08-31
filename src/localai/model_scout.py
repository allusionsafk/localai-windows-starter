"""Model Scout mode ported from ai-model-scout.ps1."""

from __future__ import annotations

import ctypes
import json
import math
import os
import re
import shutil
import subprocess
from collections.abc import Callable
from dataclasses import dataclass, replace
from datetime import UTC, datetime
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from localai.ops import CommandResult, run_command
from localai.paths import REPO_ROOT, repo_path
from localai.scout_categories import CATEGORIES, Category, category_by_id

AUTHORS = ("unsloth", "bartowski", "lmstudio-community", "Qwen", "ggml-org")
FAMILIES = (
    "qwen",
    "llama",
    "gemma",
    "mixtral",
    "mistral",
    "deepseek",
    "phi",
    "yi",
    "command",
    "glm",
    "granite",
    "olmo",
    "minimax",
    "nemotron",
    "falcon",
    "hermes",
    "smol",
    "stablelm",
    "exaone",
    "internlm",
)

PULL_TIMEOUT_SEC = 7200
CREATE_TIMEOUT_SEC = 1200
BENCHMARK_TIMEOUT_SEC = 420
FALLBACK_BASELINE = "qwen3.6-35b-a3b-grounded"
# Context a grounded wrapper bakes when no category ctx is given. Prepared tags
# at other sizes carry a "-NNk" suffix so warm/UI stay coherent (constraint #2).
DEFAULT_GROUNDED_CTX = 8192
# Only these provisional category positions may trigger per-repository
# enrichment. Six categories therefore cap the union at 18 unique finalists.
FINALISTS_PER_CATEGORY = 3
MAX_ENRICHED_FINALISTS = FINALISTS_PER_CATEGORY * len(CATEGORIES)

QUANT_PREFERENCE = (
    "Q4_K_M",
    "UD-Q4_K_XL",
    "Q4_K_S",
    "IQ4_XS",
    "IQ4_NL",
    "Q4_0",
    "Q3_K_M",
)

# Anti-hallucination grounding shared with ai-model-scout.ps1's grounded family.
GROUND_SYSTEM = """You are a precise, grounded assistant.

Answer promptly and visibly. For simple requests, arithmetic, definitions, \
short explanations, and routine choices, give the final answer directly \
without opening a reasoning loop.

For hard tasks, do one compact internal check, then answer. Do not repeat the \
same concern, restart your plan, or write recursive "wait" / "alternatively" \
loops. After one correction pass, either answer or ask one clarifying question.

If a <think>...</think> section appears, keep it brief, close it, and continue \
after </think> with a visible final answer. Never end immediately after \
thinking.

Grounding rules: do not invent facts, numbers, names, dates, quotes, \
headlines, or events. For current or real-world specifics, use only \
web-search results provided in the conversation. If no relevant search \
results are present, say you do not have current data and ask the user to \
enable web search. If you cannot verify something, say so plainly.

Keep answers concise unless the user asks for depth."""

# Chat template for qwen-family grounded wrappers (verbatim from the PS1 scout).
QWEN_TEMPLATE = '''TEMPLATE """
{{- if or .System .Tools }}<|im_start|>system
{{ if .System }}
{{ .System }}
{{- end }}
{{- if .Tools }}

# Tools

You may call one or more functions to assist with the user query.

You are provided with function signatures within <tools></tools> XML tags:
<tools>
{{- range .Tools }}
{"type": "function", "function": {{ .Function }}}
{{- end }}
</tools>

For each function call, return a json object with function name and arguments \
within <tool_call></tool_call> XML tags:
<tool_call>
{"name": <function-name>, "arguments": <args-json-object>}
</tool_call>
{{- end -}}
<|im_end|>
{{ end }}
{{- range $i, $_ := .Messages }}
{{- $last := eq (len (slice $.Messages $i)) 1 -}}
{{- if eq .Role "user" }}<|im_start|>user
{{ .Content }}<|im_end|>
{{ else if eq .Role "assistant" }}<|im_start|>assistant
{{ if .Content }}{{ .Content }}
{{- else if .ToolCalls }}<tool_call>
{{ range .ToolCalls }}{"name": "{{ .Function.Name }}", "arguments": \
{{ .Function.Arguments }}}
{{ end }}</tool_call>
{{- end }}{{ if not $last }}<|im_end|>
{{ end }}
{{- else if eq .Role "tool" }}<|im_start|>user
<tool_response>
{{ .Content }}
</tool_response><|im_end|>
{{ end }}
{{- if and (ne .Role "assistant") $last }}<|im_start|>assistant
<think>

</think>

{{ end }}
{{- end }}"""'''

# Family-appropriate conservative sampling for grounded wrappers.
SAMPLING = {
    "qwen": (
        "PARAMETER temperature 0.7\nPARAMETER top_p 0.8\nPARAMETER top_k 20\n"
        "PARAMETER min_p 0\nPARAMETER repeat_penalty 1.05"
    ),
    "gemma": "PARAMETER temperature 0.7\nPARAMETER top_p 0.95\nPARAMETER top_k 64",
    "llama": "PARAMETER temperature 0.6\nPARAMETER top_p 0.9",
    "mistral": "PARAMETER temperature 0.6\nPARAMETER top_p 0.9",
}
DEFAULT_SAMPLING = "PARAMETER temperature 0.6\nPARAMETER top_p 0.9"

# VRAM fit constants (constraint #1: weights + KV(ctx x parallel) < VRAM).
WEIGHTS_GB_PER_B = 0.6  # ~q4 bytes-per-param heuristic, matched to fit_candidate.
VRAM_OVERHEAD_GB = 1.5  # CUDA context + activations headroom.
RAM_HEADROOM_GB = 5  # OS + Docker/WSL working set kept off the model budget.
# Above this, a dense model spilling to CPU stops being merely slow. Only used
# by the flat-8k discovery pass; category_fit compares against the RAM ceiling.
DENSE_SPILL_CEILING_GB = 18
# GB of KV cache per 1k tokens (f16), bucketed by TOTAL params - KV grows with
# layer count, which tracks total size (MoE included: bucket by total, not
# active). Conservative modern-GQA estimates; the daily-driver anchor test pins
# the 9B/12GB case so drift is caught.
KV_GB_PER_1K_BUCKETS: tuple[tuple[float, float], ...] = (
    (4, 0.11),
    (14, 0.16),
    (32, 0.20),
)
KV_GB_PER_1K_DEFAULT = 0.26
# OLLAMA_KV_CACHE_TYPE -> multiplier vs f16. This box runs q8_0 + flash
# attention (see SETUP-NOTES), halving real KV; default to f16 (conservative)
# when the env var is unset.
KV_DTYPE_FACTORS: dict[str, float] = {
    "f32": 2.0,
    "f16": 1.0,
    "bf16": 1.0,
    "q8_0": 0.5,
    "q4_0": 0.25,
    "q4_1": 0.25,
}

# Bits per weight per GGUF encoding, from llama.cpp's "Tensor Encoding Schemes"
# wiki. Used only as a SECOND-tier estimate: when the exact artefact size is
# known it always wins (see resolve_weight_sizing).
#
# These are base-type figures. K-quants keep embedding/output tensors at higher
# precision, so a real Q4_K_M file is larger than 4.5 bpw implies - which is why
# the table is never allowed to shrink an estimate below WEIGHTS_GB_PER_B.
QUANT_BPW: dict[str, float] = {
    "F32": 32.0,
    "F16": 16.0,
    "BF16": 16.0,
    "Q8_0": 8.0,
    "Q8_1": 8.0,
    "Q6_K": 6.5625,
    "Q5_K": 5.5,
    "Q5_0": 5.0,
    "Q5_1": 5.0,
    "Q4_K": 4.5,
    "IQ4_NL": 4.5,
    "IQ4_XS": 4.25,
    "Q4_0": 4.0,
    "Q4_1": 4.0,
    "Q3_K": 3.4375,
    "IQ3_S": 3.4375,
    "IQ3_XXS": 3.0625,
    "Q2_K": 2.5625,
    "IQ2_S": 2.5,
    "IQ2_XS": 2.31,
    "IQ2_XXS": 2.0625,
    "IQ1_M": 1.75,
    "IQ1_S": 1.5,
}
# Size-class suffixes on a K-quant (Q4_K_M, Q4_K_S, ...). IQ types such as
# IQ4_XS are whole names and are matched before any suffix is stripped.
_QUANT_SIZE_SUFFIXES = ("_XXL", "_XL", "_XS", "_S", "_M", "_L")

# Every size in this module is compared against a hardware budget, and every one
# of those budgets is BINARY: nvidia-smi MiB / 1024, ullTotalPhys / 1024**3, and
# shutil.disk_usage().free / 1024**3. tiers.json thresholds are the same unit
# (a nominal 16 GB card reports 16376 MiB -> 16.0). So bytes are converted with
# 1024**3, not 1e9: a decimal figure would be 7.4% larger than the budget it is
# checked against, which is the wrong number even though it errs conservatively.
GIB = 1024**3


@dataclass(frozen=True)
class Budget:
    ram_gb: float
    vram_gb: float
    disk_free_gb: float


@dataclass(frozen=True)
class QuantArtefact:
    """The quant that will actually be pulled, and its exact size when known."""

    quant: str
    size_bytes: int | None
    # A filename can identify the tensor encoding but cannot establish whether
    # the weights came from PTQ, QAT, native low precision, or publisher
    # training. Do not infer origin from ``quant``.
    quant_origin: str = "unverified"
    origin_provenance: str = "filename-only"
    effective_bpw: float | None = None


@dataclass(frozen=True)
class WeightSizing:
    """Resident weight size, and how much the number can be trusted.

    ``provenance`` is one of:

    ``measured-file``     exact bytes of the artefact that will be pulled;
    ``bpw-table``         derived from the quant's bits-per-weight;
    ``global-heuristic``  ``total_params x WEIGHTS_GB_PER_B`` - today's estimate.

    ``gb`` is binary GiB in every case, matching the hardware budgets it is
    compared against (see GIB).
    """

    gb: float
    quant: str | None
    provenance: str


def quant_bits_per_weight(quant: str | None) -> float | None:
    """Bits per weight for a GGUF quant tag, or None if it is not recognised."""
    if not quant:
        return None
    name = quant.strip().upper()
    if name.startswith("UD-"):  # Unsloth dynamic quants: UD-Q4_K_XL -> Q4_K_XL
        name = name[3:]
    if name in QUANT_BPW:
        return QUANT_BPW[name]
    for suffix in _QUANT_SIZE_SUFFIXES:
        if name.endswith(suffix):
            base = name[: -len(suffix)]
            if base in QUANT_BPW:
                return QUANT_BPW[base]
            break
    return None


def resolve_weight_sizing(
    *,
    total_b: float | None,
    quant: str | None = None,
    artefact_bytes: int | None = None,
) -> WeightSizing | None:
    """Resident weight size, preferring measured evidence over estimates.

    Deliberately takes ``total_b`` and never an active-parameter count: a MoE
    loads every expert weight, so active parameters describe compute and offload
    cost and must never shrink a memory figure.

    Missing metadata must not make a model look smaller than the evidence
    supports, so when only the quant is known the estimate is the LARGER of the
    bits-per-weight figure and the global heuristic. Under-pricing is the
    dangerous direction: it reports that a model fits when it does not.
    """
    if artefact_bytes and artefact_bytes > 0:
        return WeightSizing(round(artefact_bytes / GIB, 2), quant, "measured-file")
    if total_b is None:
        return None
    heuristic = total_b * WEIGHTS_GB_PER_B
    bpw = quant_bits_per_weight(quant)
    if bpw is None:
        return WeightSizing(round(heuristic, 1), quant, "global-heuristic")
    from_bpw = total_b * bpw / 8.0
    if from_bpw > heuristic:
        return WeightSizing(round(from_bpw, 1), quant, "bpw-table")
    # A base-type figure below the heuristic understates a K-quant's
    # higher-precision tensors; keep the conservative number.
    return WeightSizing(round(heuristic, 1), quant, "global-heuristic")


@dataclass(frozen=True)
class Candidate:
    id: str
    author: str
    name: str
    total: float | None
    active: float | None
    is_moe: bool
    kind: str
    reasoning: bool
    family: str
    parse_warning: str | None
    downloads: int = 0
    age_days: int | None = None
    modified: str = ""
    verdict: str = ""
    size_gb: float | None = None
    fit_why: str = ""
    score: float = 0
    fit_stage: str = "provisional"
    fit_confidence: str = "provisional"
    residency: str = "unverified"
    weight_provenance: str = "global-heuristic"
    kv_provenance: str = "param-buckets"
    runtime_support: str = "unverified"
    runtime_provenance: str = "not-checked"
    evidence: CandidateEvidence | None = None


def collect_model_scout_report(
    *,
    mode: str = "Scout",
    top_n: int = 8,
    quiet: bool = False,
    now: datetime | None = None,
    probe_timeout_sec: int = 30,
    no_pull: bool = False,
    echo: Callable[[str], None] | None = None,
    category: str | None = None,
    vram_gb: float | None = None,
) -> tuple[int, list[str]]:
    """Run Scout or Prepare. Promote remains deliberately gated (manual only).

    ``echo`` streams each line as it is produced - Prepare runs for many
    minutes in a console window, so waiting for the final list is not an
    option there. ``quiet`` is accepted for legacy parity; the Python port
    never sends toast notifications.
    """
    del quiet
    normalized_mode = normalize_mode(mode)
    if normalized_mode not in {"Scout", "Prepare", "Promote"}:
        return 2, [f"[!] Unknown model scout mode: {mode}"]
    if normalized_mode == "Promote":
        return 2, [
            f"localai model-scout --mode {normalized_mode} is not ported to Python yet."
        ]

    stamp = now or datetime.now()
    notes: list[str] = []
    lines: list[str] = []

    def say(line: str) -> None:
        lines.append(line)
        if echo is not None:
            echo(line)

    say("")
    say(
        f"==== model scout ====  mode: {normalized_mode}   "
        f"{stamp.strftime('%Y-%m-%d %H:%M')}"
    )
    budget = get_budget(timeout_sec=probe_timeout_sec, vram_override=vram_gb)
    say(
        "budget: "
        f"{format_num(budget.vram_gb)}GB VRAM | "
        f"{format_num(budget.ram_gb)}GB RAM | "
        f"{format_num(budget.disk_free_gb)}GB free disk"
    )
    state = load_state()

    say("[*] Discovering recent GGUF releases from: " + ", ".join(AUTHORS))
    candidates = discover_candidates(budget=budget, notes=notes, now=stamp)
    for message in notes:
        say(f"    {message}")

    provisional = collect_provisional_groups(budget, candidates)
    final_ranking = collect_final_groups(budget, provisional)
    groups = final_ranking.groups
    for category_def in CATEGORIES:
        result = groups[category_def.id]
        say("")
        say(f"[{category_def.label}]")
        if result.top is None:
            say(f"  (none) {result.why}")
        else:
            _say_pick(say, "TOP ", result.top)
            for runner in result.runners_up:
                _say_pick(say, "    ", runner)
            say(f"  why: {result.why}")
        if result.dropped:
            shown = result.dropped[:top_n]
            joined = "; ".join(f"{name} ({reason})" for name, reason in shown)
            extra = len(result.dropped) - len(shown)
            suffix = f" (+{extra} more)" if extra > 0 else ""
            say(f"  dropped {len(result.dropped)} for VRAM: {joined}{suffix}")
    write_scout_groups(final_ranking, now=stamp)

    exit_code = 0
    prepare_log: list[str] = []
    pick: Candidate | None = None
    if normalized_mode == "Prepare":
        target = category or "chat"
        chosen = groups.get(target)
        pick = chosen.top if chosen else None
        say("")
        if chosen is None:
            say(f"[!] Unknown category '{target}'. Choose one of: {_category_ids()}.")
            exit_code = 2
        elif pick is None:
            say(f"[i] No VRAM-feasible pick for category '{target}' this run.")
        else:
            target_category = category_by_id(target)
            target_ctx = (
                target_category.target_ctx
                if target_category
                else DEFAULT_GROUNDED_CTX
            )
            say(
                f"[+] Preparing '{target}' top pick: {pick.name} "
                f"(num_ctx={target_ctx})"
            )
            exit_code = prepare_pick(
                pick,
                budget=budget,
                state=state,
                say=say,
                log=prepare_log,
                no_pull=no_pull,
                stream=echo is not None,
                now=stamp,
                probe_timeout_sec=probe_timeout_sec,
                num_ctx=target_ctx,
            )

    write_model_scout_log(
        mode=normalized_mode,
        now=stamp,
        groups=groups,
        pick=pick,
        notes=notes,
        prepare_lines=prepare_log,
    )
    save_state(state)
    say("")
    say("[done] log: logs\\model-scout-log.md")
    return exit_code, lines


def _category_ids() -> str:
    return ", ".join(category.id for category in CATEGORIES)


def _say_pick(say: Callable[[str], None], prefix: str, pick: Candidate) -> None:
    tag = " [thinking]" if pick.reasoning else ""
    curated = " (curated)" if pick.author == "curated" else ""
    evidence = (
        f" [{pick.fit_stage}/{pick.fit_confidence}; "
        f"runtime {pick.runtime_support}]"
    )
    size = "?" if pick.size_gb is None else format_num(pick.size_gb)
    say(
        f"  {prefix} {pick.name:<40} {pick.verdict:<6} "
        f"~{size}GB  score {format_num(pick.score)}{evidence}{curated}{tag}"
    )


def prepare_pick(
    pick: Candidate,
    *,
    budget: Budget,
    state: dict[str, list[str]],
    say: Callable[[str], None],
    log: list[str],
    no_pull: bool,
    stream: bool,
    now: datetime,
    probe_timeout_sec: int,
    num_ctx: int = DEFAULT_GROUNDED_CTX,
) -> int:
    """Pull + ground + benchmark the pick. Never touches the Open WebUI default."""
    # Cheap guard first, on the scout's own estimate: if there is already not
    # enough disk, do not spend a network round trip to learn the exact size.
    if pick.size_gb and budget.disk_free_gb < pick.size_gb + 12:
        say(
            f"[!] Low disk (need ~{format_num(pick.size_gb + 12)}GB, have "
            f"{format_num(budget.disk_free_gb)}GB). Skipping pull."
        )
        log.append(f"- SKIPPED pull (low disk): {pick.id}")
        return 0

    repo = pick.id
    # Final Scout picks already carry the tree/config results. Legacy or manual
    # callers without evidence retain the old on-demand resolution path.
    resolved = pick.evidence
    artefact = (
        resolved.artefact
        if resolved is not None
        else select_quant_artefact(repo)
    )
    quant = (artefact.quant if artefact else None) or "Q4_K_M"
    sizing = resolved.weights if resolved is not None else None
    if sizing is None:
        sizing = resolve_weight_sizing(
            total_b=pick.total,
            quant=quant,
            artefact_bytes=artefact.size_bytes if artefact else None,
        )
    # Never let a missing measurement look smaller than the scout's own estimate.
    need_gb = max(sizing.gb if sizing else 0.0, pick.size_gb or 0.0)

    say(f"[+] Quant chosen for {format_num(budget.vram_gb)}GB VRAM: {quant}")
    if sizing and sizing.provenance == "measured-file":
        estimate = pick.size_gb
        detail = f"    artefact size: {format_num(sizing.gb)}GB (measured)"
        if estimate and abs(estimate - sizing.gb) >= 0.5:
            detail += f", scout estimated {format_num(estimate)}GB"
        say(detail)
    elif sizing:
        say(f"    artefact size: ~{format_num(sizing.gb)}GB ({sizing.provenance})")

    # KV at the context this pick will actually be built with. The scout ranked
    # it from parameter-count buckets, which cannot see how many KV heads a
    # model has - a sparse MoE with few KV heads is priced more than twice its
    # real cost that way. config.json is fetched once, for the selected model
    # only, and its absence simply keeps the bucket estimate.
    arch = (
        resolved.architecture
        if resolved is not None
        else parse_architecture(fetch_hf_config(repo))
    )
    kv_gb, kv_provenance = resolve_kv_gb(
        pick.total or 0.0,
        ctx=num_ctx,
        parallel=read_num_parallel(),
        kv_factor=read_kv_factor(),
        arch=arch,
    )
    ctx_label = f"{num_ctx // 1024}k"
    if arch:
        say(
            f"    KV@{ctx_label}: {format_num(kv_gb)}GB (measured architecture: "
            f"{arch.n_layer} layers, {arch.n_head_kv} KV heads)"
        )
        if arch.native_context and num_ctx > arch.native_context:
            # Requested context is not the same thing as allocated context.
            say(
                f"    note: {ctx_label} requested is above this model's native "
                f"{arch.native_context // 1024}k; the runtime may allocate less."
            )
    else:
        say(f"    KV@{ctx_label}: ~{format_num(kv_gb)}GB ({kv_provenance})")

    # The scout ranked this candidate at an estimated size. If the real artefact
    # plus its KV reservation cannot be resident at all, stop before the
    # multi-gigabyte download rather than discovering it at load time.
    ram_ceil = budget.ram_gb - RAM_HEADROOM_GB
    if sizing and sizing.provenance == "measured-file":
        resident = round(sizing.gb + kv_gb, 2)
        if resident > ram_ceil:
            say(
                f"[!] {quant} needs ~{format_num(resident)}GB resident "
                f"({format_num(sizing.gb)}GB weights + {format_num(kv_gb)}GB "
                f"KV@{ctx_label}), over this machine's "
                f"~{format_num(ram_ceil)}GB usable memory. Skipping pull."
            )
            log.append(
                f"- SKIPPED pull ({quant} {format_num(resident)}GB resident > "
                f"{format_num(ram_ceil)}GB usable): {pick.id}"
            )
            return 0

    if need_gb and budget.disk_free_gb < need_gb + 12:
        say(
            f"[!] Low disk (need ~{format_num(need_gb + 12)}GB, have "
            f"{format_num(budget.disk_free_gb)}GB). Skipping pull."
        )
        log.append(f"- SKIPPED pull (low disk): {pick.id}")
        return 0
    if no_pull:
        say("    (--no-pull: skipping the actual download)")
        return 0

    say(f"[+] Pulling hf.co/{repo}:{quant}  (this is the big step)...")
    pulled = pull_with_retry(repo, quant, stream=stream, say=say)
    if pulled.code != 0:
        reason = _failure_reason(pulled)
        say(f"[!] prepare failed: {reason}")
        log.append(f"- PREPARE FAILED: {pick.id} - {reason}")
        return 1

    gname = grounded_model_name(pick, num_ctx)
    say(f"    building {gname} (FROM hf.co/{repo}:{quant}, num_ctx={num_ctx})")
    modelfile_path = repo_path(f"scout-{grounded_slug(pick)}.Modelfile")
    modelfile_path.write_text(
        grounded_modelfile(repo, quant, pick, now=now, num_ctx=num_ctx),
        encoding="ascii",
    )
    created = run_ollama(
        ["create", gname, "-f", str(modelfile_path)],
        timeout_sec=CREATE_TIMEOUT_SEC,
        stream=stream,
    )
    if created.code != 0:
        reason = _failure_reason(created)
        say(f"[!] grounded wrapper failed: {reason}")
        log.append(f"- PREPARE FAILED: {pick.id} - {reason}")
        return 1

    say(f"[+] Benchmarking {gname} on your GPU...")
    new_bench = measure_speed(gname, probe_timeout_sec=probe_timeout_sec)
    # Free the new model from RAM BEFORE loading the baseline. Two big models
    # loaded at once exhausted RAM and took down Docker/WSL2 on this 32GB box
    # (2026-06-13, 21GB Q4 build).
    stop_model(gname, timeout_sec=probe_timeout_sec)
    if new_bench.error or new_bench.tps <= 0:
        reason = new_bench.error or "no tokens generated"
        say(f"[!] benchmark failed for {gname}: {reason}")
        log.append(f"- PREPARE FAILED: {gname} benchmark failed: {reason}")
        return 1
    say(f"    {gname}: {format_num(new_bench.tps)} tok/s  ({new_bench.proc})")

    baseline = baseline_model()
    base_bench: BenchResult | None = None
    if model_present(baseline, timeout_sec=probe_timeout_sec):
        say(f"[+] Benchmarking your current default ({baseline}) for comparison...")
        base_bench = measure_speed(baseline, probe_timeout_sec=probe_timeout_sec)
        say(f"    {baseline}: {format_num(base_bench.tps)} tok/s  ({base_bench.proc})")
    stop_model(gname, timeout_sec=probe_timeout_sec)
    stop_model(baseline, timeout_sec=probe_timeout_sec)

    verdict = "prepared"
    if base_bench and base_bench.tps > 0:
        relation = "FASTER than" if new_bench.tps >= base_bench.tps else "slower than"
        verdict = (
            f"{relation} {baseline} "
            f"({format_num(new_bench.tps)} vs {format_num(base_bench.tps)} tok/s)"
        )
    if pick.id not in state["prepared"]:
        state["prepared"].append(pick.id)
    base_tps = format_num(base_bench.tps) if base_bench else "?"
    log.append(f"- PREPARED: {gname}  FROM hf.co/{repo}:{quant}")
    log.append(
        f"  - benchmark: {format_num(new_bench.tps)} tok/s, {new_bench.proc}; "
        f"baseline {baseline} = {base_tps} tok/s"
    )
    log.append(f"  - verdict: {verdict}")
    log.append(
        f"  - try it: pick '{gname}' in the Open WebUI model dropdown "
        f"({baseline} stays default)"
    )
    say("")
    say(
        f"[OK] {gname} is ready. It is NOT your default - pick it in "
        f"Open WebUI to A/B vs {baseline}."
    )
    say(
        "     Make it default when happy:  "
        f"pwsh -File ai-model-scout.ps1 -Mode Promote -Only {repo}"
    )
    return 0


def _failure_reason(result: CommandResult) -> str:
    return result.text.strip() or f"exit {result.code}"


PULL_ATTEMPTS = 4


def pull_with_retry(
    repo: str,
    quant: str,
    *,
    stream: bool,
    say: Callable[[str], None],
    attempts: int = PULL_ATTEMPTS,
) -> CommandResult:
    """Pull a model, retrying transient failures.

    ``ollama pull`` is idempotent and resumes from already-downloaded blobs, so
    a failed attempt is safe to retry - the bytes stay on disk. The common
    failure on a multi-GB HF model is 'context deadline exceeded' while
    finalising the manifest after the blob is fully cached; a retry then only
    has to redo the cheap manifest step. Without this, one HF hiccup aborts an
    hour-long Prepare (the 'context window ends before it can continue' report).
    """
    args = ["pull", f"hf.co/{repo}:{quant}"]
    result = run_ollama(args, timeout_sec=PULL_TIMEOUT_SEC, stream=stream)
    attempt = 1
    while result.code != 0 and attempt < attempts:
        say(
            f"    pull attempt {attempt} failed ({_failure_reason(result)}); "
            "retrying - the blob is already cached..."
        )
        attempt += 1
        result = run_ollama(args, timeout_sec=PULL_TIMEOUT_SEC, stream=stream)
    return result


def ollama_exe() -> str:
    """The user-install Ollama CLI, falling back to PATH lookup."""
    local = os.environ.get("LOCALAPPDATA")
    if local:
        candidate = Path(local) / "Programs" / "Ollama" / "ollama.exe"
        if candidate.exists():
            return str(candidate)
    return "ollama"


def run_ollama(
    args: list[str],
    *,
    timeout_sec: float,
    stream: bool = False,
) -> CommandResult:
    """Run the Ollama CLI. ``stream=True`` inherits the console so pull/create
    progress bars stay visible; output is not captured in that case."""
    argv = [ollama_exe(), *args]
    if not stream:
        return run_command(argv, cwd=REPO_ROOT, timeout_sec=timeout_sec)
    try:
        completed = subprocess.run(
            argv, cwd=REPO_ROOT, timeout=timeout_sec, check=False
        )
    except subprocess.TimeoutExpired:
        return CommandResult(
            tuple(argv), 124, "", f"Timed out after {timeout_sec:g}s\n"
        )
    except OSError as exc:
        return CommandResult(tuple(argv), 1, "", f"Launch failed: {exc}\n")
    return CommandResult(tuple(argv), completed.returncode, "", "")


def grounded_slug(candidate: Candidate) -> str:
    slug = re.sub(r"[^a-z0-9.]+", "-", candidate.name.lower()).strip("-")
    return slug[:40].strip("-") if len(slug) > 40 else slug


def grounded_model_name(
    candidate: Candidate, num_ctx: int = DEFAULT_GROUNDED_CTX
) -> str:
    """Grounded tag for a pick; non-default ctx is encoded as a ``-NNk`` suffix.

    Warm and Open WebUI derive num_ctx from that suffix (warm.resolve_num_ctx),
    so a model prepared at 32k must carry ``-32k`` or the first chat reloads it
    for a context-size mismatch (constraint #2).
    """
    base = f"{grounded_slug(candidate)}-grounded"
    if num_ctx and num_ctx != DEFAULT_GROUNDED_CTX:
        return f"{base}-{num_ctx // 1024}k"
    return base


def grounded_modelfile(
    repo: str,
    quant: str,
    candidate: Candidate,
    *,
    now: datetime,
    num_ctx: int = DEFAULT_GROUNDED_CTX,
) -> str:
    """Modelfile for a grounded wrapper around a freshly pulled HF GGUF."""
    template = QWEN_TEMPLATE if candidate.family == "qwen" else ""
    sampling = SAMPLING.get(candidate.family, DEFAULT_SAMPLING)
    return (
        f"FROM hf.co/{repo}:{quant}\n\n"
        f"# Auto-generated by localai model-scout on {now:%Y-%m-%d}. "
        "Grounded wrapper.\n"
        f"{template}\n"
        f"PARAMETER num_ctx {num_ctx}\n"
        f"{sampling}\n\n"
        f'SYSTEM """{GROUND_SYSTEM}"""\n'
    )


def select_quant_artefact(repo: str) -> QuantArtefact | None:
    """Pick a ~Q4 quant AND keep its exact file size (None on API failure).

    The HuggingFace tree response already carries a ``size`` for every file, and
    this is the single place the tree is fetched, so the exact resident size of
    the artefact that will be pulled costs no extra request. It used to be read
    for the filename and thrown away.

    A quant split across shards (``...-00001-of-00002.gguf``) has its parts
    summed, so a sharded model is not priced as one shard.
    """
    try:
        tree = fetch_hf_tree(repo)
    except (OSError, ValueError):
        return None
    quants: list[str] = []
    sizes: dict[str, int] = {}
    unsized: set[str] = set()
    for entry in tree:
        if not isinstance(entry, dict):
            continue
        path = str(entry.get("path") or "")
        if not re.search(r"(?i)\.gguf$", path):
            continue
        # Keep this deliberately narrow: these are tensor-type tags that affect
        # the selected artefact's resident bytes. They say nothing about PTQ,
        # QAT, native-low-precision, or publisher/training provenance.
        matches = re.findall(
            r"(?i)(?:UD-)?I?Q\d[0-9A-Z_]*|MXFP4|NVFP4|FP8|BF16|F16",
            path,
        )
        if not matches:
            continue
        for quant in matches:
            if quant not in quants:
                quants.append(quant)
            size = entry.get("size")
            if isinstance(size, int) and size > 0:
                sizes[quant] = sizes.get(quant, 0) + size
            else:
                unsized.add(quant)

    def artefact(quant: str) -> QuantArtefact:
        # A shard with no size would silently under-count the total, so a quant
        # with any unsized part reports no size at all rather than a low one.
        if quant in unsized:
            return QuantArtefact(quant, None)
        return QuantArtefact(quant, sizes.get(quant))

    for preferred in QUANT_PREFERENCE:
        for quant in quants:
            if quant.lower() == preferred.lower():
                return artefact(quant)
    return artefact(quants[0]) if quants else None


def best_quant(repo: str) -> str | None:
    """Pick a ~Q4 quant tag from the repo's GGUF files (None on API failure)."""
    artefact = select_quant_artefact(repo)
    return artefact.quant if artefact else None


def fetch_hf_tree(repo: str) -> list[object]:
    request = Request(
        f"https://huggingface.co/api/models/{repo}/tree/main",
        headers={"User-Agent": "localai-model-scout"},
    )
    with urlopen(request, timeout=30) as response:
        payload = json.loads(response.read().decode("utf-8"))
    return payload if isinstance(payload, list) else []


def baseline_model() -> str:
    """The current Open WebUI daily driver, read from docker-compose.yml."""
    try:
        text = repo_path("docker-compose.yml").read_text(encoding="utf-8")
    except OSError:
        return FALLBACK_BASELINE
    match = re.search(r"DEFAULT_MODELS=(\S+)", text)
    return match.group(1).strip() if match else FALLBACK_BASELINE


@dataclass(frozen=True)
class BenchResult:
    tps: float
    tokens: int
    proc: str
    error: str | None = None


def measure_speed(
    model: str,
    *,
    benchmark_timeout_sec: float = BENCHMARK_TIMEOUT_SEC,
    probe_timeout_sec: float = 30,
) -> BenchResult:
    """Real tok/s on this GPU via /api/generate, plus the CPU/GPU split."""
    body = json.dumps(
        {
            "model": model,
            "prompt": (
                "Explain how a four-stroke engine works, in two short paragraphs."
            ),
            "stream": False,
            "options": {"num_ctx": 8192},
        }
    ).encode("utf-8")
    request = Request(
        "http://localhost:11434/api/generate",
        data=body,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urlopen(request, timeout=benchmark_timeout_sec) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except (OSError, ValueError) as exc:
        return BenchResult(0, 0, "", str(exc))
    eval_count = int(payload.get("eval_count") or 0)
    eval_duration = int(payload.get("eval_duration") or 0)
    tps = round(eval_count / (eval_duration / 1e9), 1) if eval_duration > 0 else 0.0
    proc = ""
    listed = run_ollama(["ps"], timeout_sec=probe_timeout_sec)
    base_name = re.sub(r":latest$", "", model)
    for line in listed.text.splitlines():
        if base_name in line:
            match = re.search(
                r"(\d+%\s*/\s*\d+%\s*CPU/GPU|100%\s*GPU|100%\s*CPU)", line
            )
            if match:
                proc = match.group(0)
    return BenchResult(tps, eval_count, proc)


def stop_model(model: str, *, timeout_sec: float = 30) -> None:
    """Unload a model from RAM/VRAM; best-effort."""
    if model:
        run_ollama(["stop", model], timeout_sec=timeout_sec)


def model_present(model: str, *, timeout_sec: float = 30) -> bool:
    if not model:
        return False
    listed = run_ollama(["list"], timeout_sec=timeout_sec)
    return listed.code == 0 and model in listed.text


def normalize_mode(mode: str) -> str:
    return mode[:1].upper() + mode[1:].lower() if mode else mode


def get_budget(*, timeout_sec: int, vram_override: float | None = None) -> Budget:
    ram = get_ram_gb(timeout_sec=timeout_sec)
    if vram_override is not None:
        # The installer passes the vetted tier budget; trust it, don't probe.
        vram = vram_override
    else:
        probed = get_vram_gb(timeout_sec=timeout_sec)
        vram = 0.0 if probed is None else probed
    disk = round(
        shutil.disk_usage(str(REPO_ROOT.anchor or REPO_ROOT)).free / 1024**3,
        1,
    )
    return Budget(ram_gb=ram, vram_gb=vram, disk_free_gb=disk)


def get_ram_gb(*, timeout_sec: int) -> float:
    del timeout_sec
    total_bytes = get_total_physical_memory_bytes()
    if total_bytes is None:
        return 0
    return round(total_bytes / 1024**3, 1)


def get_total_physical_memory_bytes() -> int | None:
    class MemoryStatusEx(ctypes.Structure):
        _fields_ = [
            ("dwLength", ctypes.c_ulong),
            ("dwMemoryLoad", ctypes.c_ulong),
            ("ullTotalPhys", ctypes.c_ulonglong),
            ("ullAvailPhys", ctypes.c_ulonglong),
            ("ullTotalPageFile", ctypes.c_ulonglong),
            ("ullAvailPageFile", ctypes.c_ulonglong),
            ("ullTotalVirtual", ctypes.c_ulonglong),
            ("ullAvailVirtual", ctypes.c_ulonglong),
            ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
        ]

    status = MemoryStatusEx()
    status.dwLength = ctypes.sizeof(MemoryStatusEx)
    try:
        ok = ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status))
    except (AttributeError, OSError):
        return None
    if not ok:
        return None
    return int(status.ullTotalPhys)


def get_vram_gb(*, timeout_sec: int) -> float | None:
    """Total VRAM in GB from nvidia-smi, or ``None`` when it can't be read.

    Returns ``None`` (not a phantom 12) when nvidia-smi is absent or its output
    is unparseable, so a non-NVIDIA / CPU box is treated as having no GPU budget
    rather than falsely recommending models it cannot run (audit finding 4).
    """
    result = run_command(
        [
            "nvidia-smi",
            "--query-gpu=memory.total",
            "--format=csv,noheader,nounits",
        ],
        cwd=REPO_ROOT,
        timeout_sec=timeout_sec,
    )
    if result.code != 0 or not result.text.strip():
        return None
    first = result.text.splitlines()[0].strip()
    try:
        return round(float(first) / 1024, 1)
    except ValueError:
        return None


def discover_candidates(
    *,
    budget: Budget,
    notes: list[str],
    now: datetime,
) -> list[Candidate]:
    rows: list[Candidate] = []
    for author in AUTHORS:
        try:
            models = fetch_hf_models(author)
        except OSError as exc:
            notes.append(f"HF query failed for {author} : {exc}")
            continue
        for row in models:
            if not isinstance(row, dict) or not row.get("id"):
                continue
            parsed = parse_model(str(row["id"]))
            age = age_days(str(row.get("lastModified") or ""), now)
            downloads = int(row.get("downloads") or 0)
            with_score = score_candidate(
                apply_fit(
                    parsed,
                    budget,
                    downloads=downloads,
                    age=age,
                    modified=str(row.get("lastModified") or ""),
                )
            )
            rows.append(with_score)

    by_key: dict[str, Candidate] = {}
    for candidate in rows:
        key = re.sub(r"[^a-z0-9]", "", candidate.name.lower())
        if key not in by_key or candidate.score > by_key[key].score:
            by_key[key] = candidate
    return sorted(by_key.values(), key=lambda item: item.score, reverse=True)


def fetch_hf_models(author: str) -> list[object]:
    query = urlencode(
        {
            "author": author,
            "filter": "gguf",
            "sort": "lastModified",
            "direction": "-1",
            "limit": "25",
        }
    )
    request = Request(
        f"https://huggingface.co/api/models?{query}",
        headers={"User-Agent": "localai-model-scout"},
    )
    with urlopen(request, timeout=30) as response:
        payload = json.loads(response.read().decode("utf-8"))
    return payload if isinstance(payload, list) else []


def parse_model(model_id: str) -> Candidate:
    author, _, repo = model_id.partition("/")
    name = re.sub(r"(?i)-?GGUF$", "", repo)
    clean = re.sub(r"^[A-Za-z0-9.]+_", "", name)
    lower = name.lower()

    total: float | None = None
    active: float | None = None
    is_moe = False
    active_match = re.search(r"(?i)A(\d+(?:\.\d+)?)B", name)
    if active_match:
        active = float(active_match.group(1))
        is_moe = True
    moe_match = re.search(r"(?i)(\d+(?:\.\d+)?)x(\d+(?:\.\d+)?)B", name)
    if moe_match:
        is_moe = True
        total = float(moe_match.group(1)) * float(moe_match.group(2))
    if total is None:
        for match in re.finditer(r"(?i)(?<![A-Za-z])A?(\d+(?:\.\d+)?)B", name):
            value = float(match.group(1))
            if not re.match(r"(?i)^A", match.group(0)):
                total = value if total is None else max(total, value)
    if re.search(r"moe|-a\d", lower):
        is_moe = True

    kind = model_kind(lower)
    reasoning = bool(re.search(r"thinking|reasoning|-r1|deepseek-r|-cot", lower))
    parse_warning = (
        None if total is not None else f"WARN: unrecognized model name pattern: {name}"
    )
    family = next((family for family in FAMILIES if family in lower), "other")
    return Candidate(
        id=model_id,
        author=author,
        name=clean,
        total=total,
        active=active,
        is_moe=is_moe,
        kind=kind,
        reasoning=reasoning,
        family=family,
        parse_warning=parse_warning,
    )


def model_kind(lower_name: str) -> str:
    checks = (
        ("coder", r"coder|code"),
        ("vision", r"vl|vision|image-text|multimodal|omni"),
        ("embed", r"embed|gte|bge|e5"),
        ("rerank", r"rerank"),
        ("guard", r"guard|safety|moderation"),
        ("diffusion", r"diffusion|image-gen|text-to-image"),
        ("audio", r"audio|voice|tts|asr|speech"),
        ("math", r"math|prover"),
        ("edge", r"mobile|edge|nano|tiny|-e\db"),
    )
    return next(
        (kind for kind, pattern in checks if re.search(pattern, lower_name)),
        "general",
    )


def apply_fit(
    candidate: Candidate,
    budget: Budget,
    *,
    downloads: int,
    age: int | None,
    modified: str,
) -> Candidate:
    verdict, size, why = fit_candidate(candidate, budget)
    return Candidate(
        **{
            **candidate.__dict__,
            "downloads": downloads,
            "age_days": age,
            "modified": modified,
            "verdict": verdict,
            "size_gb": size,
            "fit_why": why,
        }
    )


def kv_gb_per_1k(total_b: float) -> float:
    """GB of f16 KV cache per 1k context tokens for a model of ``total_b`` B."""
    for ceiling, value in KV_GB_PER_1K_BUCKETS:
        if total_b <= ceiling:
            return value
    return KV_GB_PER_1K_DEFAULT


def estimate_kv_gb(
    total_b: float,
    *,
    ctx: int,
    parallel: int,
    kv_factor: float,
) -> float:
    """KV-cache reservation in GB for ``ctx`` tokens across ``parallel`` slots."""
    return round(kv_gb_per_1k(total_b) * (ctx / 1024) * parallel * kv_factor, 2)


@dataclass(frozen=True)
class ArchitectureInfo:
    """The model-structure fields KV cache size actually depends on.

    Deliberately excludes any parameter count. KV scales with layers, KV heads
    and head dimension - not with how many parameters a model has, and not with
    how many of them are active per token. A sparse MoE with few KV heads has a
    small KV cache however large it is.
    """

    n_layer: int
    n_head_kv: int
    head_dim: int
    native_context: int | None = None


@dataclass(frozen=True)
class CandidateEvidence:
    """Per-repository evidence resolved once for final category fitting."""

    artefact: QuantArtefact | None
    weights: WeightSizing | None
    architecture: ArchitectureInfo | None
    runtime_support: str = "unverified"
    runtime_provenance: str = "no-positive-runtime-evidence"


def parse_architecture(config: object) -> ArchitectureInfo | None:
    """Read an ``ArchitectureInfo`` out of a HuggingFace ``config.json``.

    Returns ``None`` unless every field KV needs is present and sane, so partial
    or malformed metadata falls back to the bucket estimator rather than
    producing a confident wrong number.
    """
    if not isinstance(config, dict):
        return None

    def positive_int(*keys: str) -> int | None:
        for key in keys:
            value = config.get(key)
            if isinstance(value, bool):  # bool is an int subclass; not a count
                continue
            if isinstance(value, int) and value > 0:
                return value
        return None

    n_layer = positive_int("num_hidden_layers", "n_layer")
    # Multi-head attention omits num_key_value_heads; it then equals the head
    # count. Absent both, there is nothing to compute from.
    n_head_kv = positive_int("num_key_value_heads", "num_attention_heads")
    head_dim = positive_int("head_dim")
    if head_dim is None:
        hidden = positive_int("hidden_size", "n_embd")
        heads = positive_int("num_attention_heads", "n_head")
        if hidden and heads and hidden % heads == 0:
            head_dim = hidden // heads
    if not (n_layer and n_head_kv and head_dim):
        return None
    return ArchitectureInfo(
        n_layer=n_layer,
        n_head_kv=n_head_kv,
        head_dim=head_dim,
        native_context=positive_int("max_position_embeddings"),
    )


def exact_kv_gb(
    arch: ArchitectureInfo,
    *,
    ctx: int,
    parallel: int,
    kv_factor: float,
) -> float:
    """KV-cache reservation in GiB from the model's real structure.

    The canonical llama.cpp shape, one K cache and one V cache per layer:

        n_layer x 2 x ctx x n_head_kv x head_dim x bytes_per_element x parallel

    ``kv_factor`` carries the runtime's cache dtype relative to f16 (2 bytes),
    so OLLAMA_KV_CACHE_TYPE=q8_0 halves this exactly as it does for the bucket
    estimator.
    """
    bytes_per_element = 2.0 * kv_factor  # f16 baseline
    total = (
        arch.n_layer
        * 2
        * max(ctx, 0)
        * arch.n_head_kv
        * arch.head_dim
        * bytes_per_element
        * max(parallel, 1)
    )
    return round(total / GIB, 2)


def resolve_kv_gb(
    total_b: float,
    *,
    ctx: int,
    parallel: int,
    kv_factor: float,
    arch: ArchitectureInfo | None = None,
) -> tuple[float, str]:
    """KV size and its provenance: exact structure when known, buckets otherwise.

    Never returns zero for a real context: an absent or unusable architecture
    falls through to the parameter-count buckets, which is today's behaviour.
    """
    if arch is not None:
        return exact_kv_gb(arch, ctx=ctx, parallel=parallel, kv_factor=kv_factor), (
            "exact-architecture"
        )
    return (
        estimate_kv_gb(total_b, ctx=ctx, parallel=parallel, kv_factor=kv_factor),
        "param-buckets",
    )


def fetch_hf_config(repo: str) -> object | None:
    """Fetch a repository's ``config.json``, or ``None`` when it has none.

    One request, and only ever for a model that has already been selected - the
    same rule as the artefact size. GGUF repositories vary: unsloth's carry a
    config.json, bartowski's do not, which is exactly why the bucket fallback
    stays.
    """
    request = Request(
        f"https://huggingface.co/{repo}/resolve/main/config.json",
        headers={"User-Agent": "localai-model-scout"},
    )
    try:
        with urlopen(request, timeout=30) as response:
            parsed: object = json.loads(response.read().decode("utf-8"))
    except (OSError, ValueError):
        return None
    return parsed


def enrich_candidate(candidate: Candidate) -> CandidateEvidence:
    """Resolve the two existing remote evidence sources for one finalist.

    A successful GGUF/config lookup is sizing evidence, not proof that the
    installed runtime supports the architecture, template, parser, projector,
    or backend. Runtime support therefore remains unverified unless a future
    positive compatibility source supplies a different status.
    """
    artefact = select_quant_artefact(candidate.id)
    sizing = resolve_weight_sizing(
        total_b=candidate.total,
        quant=artefact.quant if artefact else None,
        artefact_bytes=artefact.size_bytes if artefact else None,
    )
    architecture = parse_architecture(fetch_hf_config(candidate.id))
    return CandidateEvidence(
        artefact=artefact,
        weights=sizing,
        architecture=architecture,
    )


def read_num_parallel() -> int:
    """Ollama parallel-request slots (OLLAMA_NUM_PARALLEL); default 1 on this box."""
    try:
        value = int(os.environ.get("OLLAMA_NUM_PARALLEL", ""))
    except ValueError:
        return 1
    return value if value >= 1 else 1


def read_kv_factor() -> float:
    """KV-cache size multiplier vs f16 from OLLAMA_KV_CACHE_TYPE (default f16)."""
    raw = os.environ.get("OLLAMA_KV_CACHE_TYPE", "").strip().lower()
    return KV_DTYPE_FACTORS.get(raw, 1.0)


@dataclass(frozen=True)
class FitEstimate:
    """Category-aware verdict with fit stage, residency, and provenance."""

    verdict: str
    weights_gb: float
    kv_gb: float
    why: str
    stage: str = "provisional"
    confidence: str = "provisional"
    residency: str = "unverified"
    weight_provenance: str = "global-heuristic"
    kv_provenance: str = "param-buckets"
    runtime_support: str = "unverified"
    runtime_provenance: str = "not-checked"


def category_fit(
    candidate: Candidate,
    budget: Budget,
    *,
    ctx: int,
    parallel: int,
    kv_factor: float,
    evidence: CandidateEvidence | None = None,
    final: bool = False,
) -> FitEstimate:
    """Fit a candidate at a category's target context, counting KV cache.

    Unlike :func:`fit_candidate` (weights-only, flat 8k), this folds the
    KV-cache reservation for ``ctx`` x ``parallel`` slots into the demand so a
    model that fits at 8k but spills at 32k is reported honestly.
    """
    ctx_label = f"{ctx // 1024}k"
    stage = "final" if final else "provisional"
    runtime_support = "unverified"
    runtime_provenance = "not-checked"
    if final and evidence is not None:
        runtime_provenance = evidence.runtime_provenance
        if evidence.runtime_support == "unsupported" and runtime_provenance in {
            "",
            "not-checked",
            "no-positive-runtime-evidence",
        }:
            # A label without positive evidence is still absence of evidence.
            runtime_support = "unverified"
        elif evidence.runtime_support in {"supported", "unsupported", "unverified"}:
            runtime_support = evidence.runtime_support

    if candidate.total is None:
        return FitEstimate(
            "Unknown",
            0.0,
            0.0,
            candidate.parse_warning or "WARN: size not in name",
            stage=stage,
            confidence="unverified" if final else "provisional",
            residency="unverified",
            runtime_support=runtime_support,
            runtime_provenance=runtime_provenance,
        )
    sizing = evidence.weights if final and evidence is not None else None
    if sizing is None:
        sizing = resolve_weight_sizing(total_b=candidate.total)
    weights = sizing.gb if sizing is not None else 0.0
    weight_provenance = sizing.provenance if sizing else "unverified"
    architecture = evidence.architecture if final and evidence is not None else None
    kv, kv_provenance = resolve_kv_gb(
        candidate.total,
        ctx=ctx,
        parallel=parallel,
        kv_factor=kv_factor,
        arch=architecture,
    )
    confidence = "provisional"
    if final:
        confidence = (
            "exact"
            if weight_provenance == "measured-file"
            and kv_provenance == "exact-architecture"
            else "fallback"
        )
    vram_usable = budget.vram_gb - VRAM_OVERHEAD_GB
    ram_ceil = budget.ram_gb - RAM_HEADROOM_GB
    demand = round(weights + kv, 2)

    def result(verdict: str, why: str, residency: str) -> FitEstimate:
        if final:
            why += (
                f" [final; {weight_provenance}; {kv_provenance}; "
                f"runtime {runtime_support}]"
            )
        return FitEstimate(
            verdict,
            weights,
            kv,
            why,
            stage=stage,
            confidence=confidence,
            residency=residency,
            weight_provenance=weight_provenance,
            kv_provenance=kv_provenance,
            runtime_support=runtime_support,
            runtime_provenance=runtime_provenance,
        )

    if runtime_support == "unsupported":
        return result(
            "Unsupported",
            f"runtime incompatibility proven by {runtime_provenance}",
            "unsupported",
        )

    # All expert weights must fit RAM+VRAM even for MoE (only the active experts
    # compute per token, but the whole model is resident), so the RAM ceiling
    # gates MoE and dense alike - checked before the MoE speed verdict.
    if weights > ram_ceil:
        return result(
            "TooBig",
            f"~{format_num(weights)}GB weights > RAM budget",
            "not-loadable",
        )

    # "Good" means one thing on every path: weights + KV are resident in VRAM.
    # Being MoE does not shrink that demand - low ACTIVE parameters cut the
    # compute per token, but every expert weight still has to be somewhere. So
    # the VRAM test is identical for MoE and dense; what MoE legitimately buys is
    # a cheaper SPILL, and that is scored below.
    moe_detail = ""
    if candidate.is_moe:
        moe_detail = (
            f"MoE ~{format_num(candidate.active)}B active, "
            if candidate.active
            else "MoE, "
        )

    if demand <= vram_usable:
        return result(
            "Good",
            f"{moe_detail}~{format_num(weights)}GB + {format_num(kv)}GB "
            f"KV@{ctx_label} fits {format_num(budget.vram_gb)}GB VRAM",
            "full-gpu",
        )
    if demand <= ram_ceil:
        # Past this point the model spills to CPU. A low-active MoE reads far
        # fewer weights per token than a dense model of the same footprint, so
        # the offload is genuinely cheaper - "OK" outranks dense's "Tight" in
        # score_candidate. It is still not "Good": it does not fit VRAM.
        if candidate.is_moe and candidate.active and candidate.active <= 6:
            return result(
                "OK",
                f"{moe_detail}~{format_num(demand)}GB (weights+KV@{ctx_label}) "
                "spills to CPU, but few active weights = tolerable",
                "host-loadable",
            )
        return result(
            "Tight",
            f"{moe_detail}~{format_num(demand)}GB (weights+KV@{ctx_label}) "
            "spills to CPU = slower",
            "host-loadable",
        )
    return result(
        "Poor",
        f"{moe_detail}~{format_num(demand)}GB (weights+KV@{ctx_label}) "
        "= heavy CPU offload",
        "non-interactive",
    )


def candidate_eligible_for(candidate: Candidate, category: Category) -> bool:
    """True if this candidate's kind is one the category accepts."""
    return candidate.kind in category.kinds


_FIT_SCORE = {"Good": 100.0, "OK": 60.0, "Tight": 25.0, "Poor": 5.0}


def _effective_params(candidate: Candidate) -> float:
    """Params that drive speed: active for MoE, total for dense."""
    if candidate.is_moe and candidate.active:
        return candidate.active
    return candidate.total or 999


def _speed_score(params: float) -> float:
    if params <= 3:
        return 100.0
    if params <= 8:
        return 80.0
    if params <= 14:
        return 55.0
    if params <= 32:
        return 35.0
    return 15.0


def _freshness_score(age_days: int | None) -> float:
    if age_days is None:
        return 0.0
    if age_days <= 21:
        return 100.0
    if age_days <= 45:
        return 60.0
    if age_days <= 90:
        return 30.0
    return 0.0


def _kind_match_score(candidate: Candidate, category: Category) -> float:
    if category.kinds and candidate.kind == category.kinds[0]:
        return 100.0  # exact primary kind for this task
    if candidate.kind in category.kinds:
        return 60.0  # an accepted fallback (e.g. a general model for coding)
    return 0.0


def score_for_category(
    candidate: Candidate,
    category: Category,
    fit: FitEstimate,
) -> float:
    """Weighted axis score of a candidate for one task category.

    The caller decides eligibility (:func:`candidate_eligible_for`) and VRAM
    feasibility (``fit.verdict``); this ranks the survivors. Each axis is on a
    0-100 scale and multiplied by the category's weight for it, so a negative
    weight (web-nav penalising ``reasoning``) subtracts.
    """
    axis_scores = {
        "fit": _FIT_SCORE.get(fit.verdict, 0.0),
        "popularity": min(math.log10(max(candidate.downloads, 1)) * 20, 100.0),
        "freshness": _freshness_score(candidate.age_days),
        "speed": _speed_score(_effective_params(candidate)),
        "kind_match": _kind_match_score(candidate, category),
        "family": 100.0 if candidate.family != "other" else 0.0,
        "reasoning": 100.0 if candidate.reasoning else 0.0,
    }
    total = sum(
        weight * axis_scores[axis] for axis, weight in category.weights
    )
    return round(total, 1)


# Verdicts we treat as VRAM-infeasible for a best-pick: too big for RAM, size
# unknown, or usable only via heavy CPU offload. "Tight" (minor spill) stays.
_INFEASIBLE_VERDICTS = frozenset({"TooBig", "Unknown", "Poor", "Unsupported"})


@dataclass(frozen=True)
class CategoryResult:
    """The scout's recommendation for one task category."""

    category: str
    top: Candidate | None
    runners_up: tuple[Candidate, ...]
    why: str
    dropped: tuple[tuple[str, str], ...]  # (model name, VRAM-drop reason)


@dataclass(frozen=True)
class ProvisionalRanking:
    """Internal cheap ranking. Public serializers intentionally reject it."""

    groups: dict[str, CategoryResult]


@dataclass(frozen=True)
class FinalRanking:
    """Enriched category ranking safe for CLI, cache, and dashboard output."""

    groups: dict[str, CategoryResult]


def _curated_candidate(tag: str) -> Candidate:
    """A minimal candidate for a hand-picked known-good tag (no HF metadata)."""
    return replace(
        parse_model(f"curated/{tag}"), author="curated", downloads=0, age_days=None
    )


def _compose_category_why(top: Candidate, category: Category) -> str:
    axes = sorted(category.weights, key=lambda item: abs(item[1]), reverse=True)[:2]
    emphasis = ", ".join(axis for axis, _weight in axes)
    return f"Best on {emphasis} for {category.label.lower()}: {top.fit_why}"


def collect_scout_groups(
    budget: Budget,
    candidates: list[Candidate],
    *,
    parallel: int | None = None,
    kv_factor: float | None = None,
    final: bool = False,
) -> dict[str, CategoryResult]:
    """Group candidates into a best pick + runners-up per task category.

    Curated seeds are merged into each category's pool so a sparse HuggingFace
    feed still yields a pick; a real, popular discovery outscores a seed.
    VRAM-infeasible candidates are excluded and recorded in ``dropped`` with the
    reason (stating the context length they were judged at).
    """
    slots = read_num_parallel() if parallel is None else parallel
    factor = read_kv_factor() if kv_factor is None else kv_factor
    results: dict[str, CategoryResult] = {}
    for category in CATEGORIES:
        pool = [*candidates, *(_curated_candidate(tag) for tag in category.curated)]
        scored: list[Candidate] = []
        dropped: list[tuple[str, str]] = []
        seen: set[str] = set()
        for candidate in pool:
            if not candidate_eligible_for(candidate, category):
                continue
            key = re.sub(r"[^a-z0-9]", "", candidate.name.lower())
            if key in seen:
                continue
            curated = candidate.author == "curated"
            candidate_evidence = candidate.evidence if final else None
            if final and candidate_evidence is None:
                candidate_evidence = CandidateEvidence(
                    artefact=None,
                    weights=resolve_weight_sizing(total_b=candidate.total),
                    architecture=None,
                    runtime_support="unverified",
                    runtime_provenance=(
                        "curated-without-remote-evidence"
                        if curated
                        else "missing-finalist-evidence"
                    ),
                )
            fit = category_fit(
                candidate,
                budget,
                ctx=category.target_ctx,
                parallel=slots,
                kv_factor=factor,
                evidence=candidate_evidence,
                final=final,
            )
            if fit.verdict in _INFEASIBLE_VERDICTS:
                if not curated:
                    dropped.append((candidate.name, fit.why))
                    continue
                # A pre-vetted seed with no size metadata: trust it at this ctx.
                fit = replace(
                    fit,
                    verdict="OK",
                    why=f"curated seed (assumed to fit {category.target_ctx // 1024}k)",
                    confidence="unverified" if final else fit.confidence,
                    residency="unverified" if final else fit.residency,
                )
            seen.add(key)
            scored.append(
                replace(
                    candidate,
                    score=score_for_category(candidate, category, fit),
                    verdict=fit.verdict,
                    size_gb=round(fit.weights_gb + fit.kv_gb, 1),
                    fit_why=fit.why,
                    fit_stage=fit.stage,
                    fit_confidence=fit.confidence,
                    residency=fit.residency,
                    weight_provenance=fit.weight_provenance,
                    kv_provenance=fit.kv_provenance,
                    runtime_support=fit.runtime_support,
                    runtime_provenance=fit.runtime_provenance,
                    evidence=candidate_evidence,
                )
            )
        scored.sort(key=lambda item: item.score, reverse=True)
        top = scored[0] if scored else None
        runners = tuple(scored[1:3])
        why = (
            _compose_category_why(top, category)
            if top
            else (category.note or "No VRAM-feasible candidate found this run.")
        )
        results[category.id] = CategoryResult(
            category.id, top, runners, why, tuple(dropped)
        )
    return results


def collect_provisional_groups(
    budget: Budget,
    candidates: list[Candidate],
    *,
    parallel: int | None = None,
    kv_factor: float | None = None,
) -> ProvisionalRanking:
    """Build the cheap internal ranking used only to select finalists."""
    return ProvisionalRanking(
        collect_scout_groups(
            budget,
            candidates,
            parallel=parallel,
            kv_factor=kv_factor,
            final=False,
        )
    )


def select_bounded_finalists(
    provisional: ProvisionalRanking,
) -> tuple[Candidate, ...]:
    """Union and repo-dedupe the top three candidates from every category."""
    finalists: list[Candidate] = []
    seen: set[str] = set()
    for category in CATEGORIES:
        result = provisional.groups[category.id]
        for candidate in (result.top, *result.runners_up):
            if candidate is None or candidate.author == "curated":
                continue
            if candidate.id in seen:
                continue
            seen.add(candidate.id)
            finalists.append(candidate)
    return tuple(finalists[:MAX_ENRICHED_FINALISTS])


def enrich_finalists(finalists: tuple[Candidate, ...]) -> tuple[Candidate, ...]:
    """Enrich each unique bounded finalist once within this scout execution."""
    enriched: list[Candidate] = []
    seen: set[str] = set()
    for candidate in finalists[:MAX_ENRICHED_FINALISTS]:
        if candidate.id in seen:
            continue
        seen.add(candidate.id)
        enriched.append(
            replace(
                candidate,
                evidence=enrich_candidate(candidate),
                fit_stage="final",
            )
        )
    return tuple(enriched)


def collect_final_groups(
    budget: Budget,
    provisional: ProvisionalRanking,
    *,
    parallel: int | None = None,
    kv_factor: float | None = None,
) -> FinalRanking:
    """Enrich the bounded union, recompute final fit, and rerank every category."""
    finalists = enrich_finalists(select_bounded_finalists(provisional))
    return FinalRanking(
        collect_scout_groups(
            budget,
            list(finalists),
            parallel=parallel,
            kv_factor=kv_factor,
            final=True,
        )
    )


def _candidate_to_dict(candidate: Candidate | None) -> dict[str, object] | None:
    if candidate is None:
        return None
    return {
        "id": candidate.id,
        "name": candidate.name,
        "verdict": candidate.verdict,
        "sizeGb": candidate.size_gb,
        "score": candidate.score,
        "reasoning": candidate.reasoning,
        "curated": candidate.author == "curated",
        "downloads": candidate.downloads,
        "family": candidate.family,
        "why": candidate.fit_why,
        "fitStage": candidate.fit_stage,
        "fitConfidence": candidate.fit_confidence,
        "residency": candidate.residency,
        "weightProvenance": candidate.weight_provenance,
        "kvProvenance": candidate.kv_provenance,
        "runtimeSupport": candidate.runtime_support,
        "runtimeProvenance": candidate.runtime_provenance,
        "tensorType": (
            candidate.evidence.artefact.quant
            if candidate.evidence and candidate.evidence.artefact
            else None
        ),
        "quantOrigin": (
            candidate.evidence.artefact.quant_origin
            if candidate.evidence and candidate.evidence.artefact
            else "unverified"
        ),
    }


def groups_to_dict(ranking: FinalRanking | ProvisionalRanking) -> dict[str, object]:
    """JSON-able final report; provisional rankings cannot cross this boundary."""
    if isinstance(ranking, ProvisionalRanking):
        raise ValueError("provisional ranking cannot be serialized as final")
    groups = ranking.groups
    for result in groups.values():
        for candidate in (result.top, *result.runners_up):
            if candidate is not None and candidate.fit_stage != "final":
                raise ValueError("final ranking contains a non-final-stage candidate")
    return {
        cid: {
            "category": result.category,
            "top": _candidate_to_dict(result.top),
            "runnersUp": [_candidate_to_dict(c) for c in result.runners_up],
            "why": result.why,
            "dropped": [
                {"name": name, "reason": reason} for name, reason in result.dropped
            ],
        }
        for cid, result in groups.items()
    }


def write_scout_groups(ranking: FinalRanking, *, now: datetime) -> None:
    """Persist the grouped report the dashboard reads (logs/model-scout-groups.json)."""
    path = repo_path("logs", "model-scout-groups.json")
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "generated": now.strftime("%Y-%m-%d %H:%M"),
        "fitStage": "final",
        "groups": groups_to_dict(ranking),
    }
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def read_scout_groups() -> dict[str, object] | None:
    """The cached grouped report, or None when the scout has not run yet."""
    path = repo_path("logs", "model-scout-groups.json")
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(data, dict) or data.get("fitStage") != "final":
        # Pre-final-fit caches contain provisional verdicts. Never let an old
        # ``Good`` regain authority merely because the dashboard started first.
        return None
    return data


def fit_candidate(
    candidate: Candidate,
    budget: Budget,
) -> tuple[str, float | None, str]:
    if candidate.total is None:
        return "Unknown", None, candidate.parse_warning or "WARN: size not in name"
    # Use the named constants rather than repeating their values: the literals
    # here had drifted out of the definitions above, so editing WEIGHTS_GB_PER_B
    # silently changed nothing on this path.
    size = round(candidate.total * WEIGHTS_GB_PER_B, 1)
    ram_ceil = budget.ram_gb - RAM_HEADROOM_GB
    vram_usable = budget.vram_gb - VRAM_OVERHEAD_GB
    if size > ram_ceil:
        return "TooBig", size, f"~{format_num(size)}GB > RAM budget"

    # Same rule as category_fit: MoE changes compute per token, not residency,
    # so it gets no discount on the VRAM test. Every expert weight is loaded.
    moe_detail = ""
    if candidate.is_moe:
        moe_detail = (
            f"MoE ~{format_num(candidate.active)}B active, "
            if candidate.active
            else "MoE, "
        )
    if size <= vram_usable:
        return (
            "Good",
            size,
            f"{moe_detail}~{format_num(size)}GB fits fully in {budget.vram_gb}GB VRAM",
        )
    # It spills. A low-active MoE reads far fewer weights per token than a dense
    # model of the same footprint, so the offload is cheaper - but it is still
    # not resident, so it is never "Good".
    if candidate.is_moe and candidate.active and candidate.active <= 6:
        return (
            "OK",
            size,
            f"{moe_detail}~{format_num(size)}GB spills to CPU, "
            "but few active weights = tolerable",
        )
    if size <= DENSE_SPILL_CEILING_GB:
        why = f"{moe_detail}~{format_num(size)}GB spills to CPU = slower"
        return "Tight", size, why
    return "Poor", size, f"{moe_detail}~{format_num(size)}GB = heavy CPU offload"


def score_candidate(candidate: Candidate) -> Candidate:
    if candidate.kind != "general":
        score: float = -1
    else:
        score = {"Good": 100, "OK": 60, "Tight": 25}.get(candidate.verdict, 0)
        if candidate.family != "other":
            score += 30
        if candidate.downloads:
            score += min(math.log10(max(candidate.downloads, 1)) * 10, 40)
        if candidate.age_days is not None:
            if candidate.age_days <= 21:
                score += 20
            elif candidate.age_days <= 45:
                score += 10
        if (
            candidate.is_moe
            and (candidate.total or 0) >= 24
            and (candidate.active or 999) <= 6
        ) or (
            not candidate.is_moe
            and (candidate.total or 0) >= 12
            and (candidate.total or 0) <= 16
        ):
            score += 20
        if candidate.reasoning and candidate.family != "other":
            score += 8
    return Candidate(**{**candidate.__dict__, "score": round(score, 1)})


def age_days(value: str, now: datetime) -> int | None:
    if not value:
        return None
    try:
        modified = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    compare_now = now
    if modified.tzinfo is not None and compare_now.tzinfo is None:
        compare_now = compare_now.replace(tzinfo=UTC)
    return int((compare_now - modified).total_seconds() // 86400)


def load_state() -> dict[str, list[str]]:
    path = repo_path("logs", "model-scout-state.json")
    if not path.exists():
        return {"prepared": [], "seen": []}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"prepared": [], "seen": []}
    if not isinstance(payload, dict):
        return {"prepared": [], "seen": []}
    return {
        "prepared": list(payload.get("prepared") or []),
        "seen": list(payload.get("seen") or []),
    }


def save_state(state: dict[str, list[str]]) -> None:
    path = repo_path("logs", "model-scout-state.json")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, indent=2), encoding="utf-8")


def write_model_scout_log(
    *,
    mode: str,
    now: datetime,
    groups: dict[str, CategoryResult],
    pick: Candidate | None,
    notes: list[str],
    prepare_lines: list[str] | None = None,
) -> None:
    path = repo_path("logs", "model-scout-log.md")
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [f"## {now.strftime('%Y-%m-%d %H:%M')}  (mode: {mode})"]
    for category in CATEGORIES:
        result = groups[category.id]
        if result.top is None:
            lines.append(f"- **{category.label}**: (none) - {result.why}")
            continue
        top = result.top
        tag = " [thinking]" if top.reasoning else ""
        size = "?" if top.size_gb is None else format_num(top.size_gb)
        runners = ", ".join(runner.name for runner in result.runners_up)
        lines.append(
            f"- **{category.label}**: {top.name} | fit:{top.verdict} ~{size}GB | "
            f"score:{format_num(top.score)}{tag} | "
            f"stage:{top.fit_stage}/{top.fit_confidence} | "
            f"residency:{top.residency} | "
            f"weights:{top.weight_provenance} | kv:{top.kv_provenance} | "
            f"runtime:{top.runtime_support}"
            + (f" | runners-up: {runners}" if runners else "")
        )
        if result.dropped:
            lines.append(
                f"  - dropped {len(result.dropped)} for VRAM: "
                + "; ".join(f"{name} ({reason})" for name, reason in result.dropped)
            )
    if pick is not None and mode == "Scout":
        lines.append(f"- TOP PICK (not pulled, Scout mode): {pick.id}")
    lines.extend(prepare_lines or [])
    for message in notes:
        lines.append(f"- note: {message}")
    lines.append("")

    header = (
        "# localai model-scout log\n\n"
        "Newest first. The scout finds/benchmarks new models; it never changes "
        "your default unless you run -Mode Promote.\n\n"
    )
    existing = path.read_text(encoding="utf-8") if path.exists() else header
    marker = "unless you run -Mode Promote.\n\n"
    if marker in existing:
        prefix, rest = existing.split(marker, 1)
        content = prefix + marker + "\n".join(lines) + "\n" + rest
    else:
        content = existing + "\n".join(lines) + "\n"
    path.write_text(content, encoding="utf-8")


def format_num(value: float) -> str:
    return str(int(value)) if float(value).is_integer() else f"{value:.1f}"
