# Model Scout bounded final-fit design

Status: approved for implementation

Base: `feat/scout-exact-kv` at
`2cd49ac6696237baae6ae9789e0f8ce5891d2e2f`

## Problem

Discovery currently assigns fit verdicts from filename parameter counts and
bucketed KV estimates. Those provisional values choose de-duplication winners,
category winners, cached JSON, dashboard badges, and CLI/log output. Only after
that does `prepare_pick` resolve the selected GGUF bytes and architecture. It
can refuse an impossible pull, but it does not recompute or rerank the category,
so a contradicted provisional `Good` remains exposed as authoritative.

## Pipeline

The scout will have two structurally distinct stages:

1. `discover_candidates` keeps its five bounded author-list requests and emits
   candidates whose fit stage is `provisional`. It performs no repository tree
   or config fetch.
2. Provisional category scoring retains the top three candidates per category.
3. The six category shortlists are unioned and de-duplicated by repository,
   yielding at most 18 remote finalists regardless of discovery size.
4. Each unique finalist is enriched once with the existing GGUF tree request
   and existing config request, then carries that evidence for the rest of the run.
5. Categories are rebuilt only from finalists, using resolved evidence, and are
   reranked without privileging the provisional winner.
6. Only the final groups are printed, logged, cached, and sent to the dashboard.
7. `prepare_pick` consumes the winning candidate's attached evidence; it
   fetches only when called with an unenriched legacy/manual candidate.

The enrichment bound is therefore 18 unique repositories and at most two
requests per repository: 36 requests. Cross-category duplicates lower the
actual count. Discovery remains independent of this count.

## Data contracts

`CandidateEvidence` is the small final-stage object. It records:

- selected `QuantArtefact`, including tensor type, exact bytes when known,
  effective BPW only when evidenced, and quantization-origin status;
- resolved `WeightSizing` and its measured/BPW/heuristic provenance;
- parsed `ArchitectureInfo`, plus exact or bucket KV provenance at fit time;
- runtime support status (`supported`, `unsupported`, or `unverified`) and its
  provenance.

Filename tensor tags never establish PTQ, QAT, native-low-precision, or
publisher-trained origin. Origin stays `unverified` without positive metadata.
Likewise, missing runtime evidence is `unverified`; only positive incompatible
evidence may produce `unsupported`.

`Candidate` carries an explicit stage (`provisional` or `final`) and optional
evidence. Final public serialization rejects or omits provisional candidates,
so adding cosmetic text cannot accidentally make provisional results final.
Serialized picks include stage, confidence/provenance, residency, and runtime
support for CLI/dashboard transparency.

`FitEstimate` separates:

- recommendation verdict (`Good`, `OK`, `Tight`, `Poor`, `TooBig`, `Unknown`,
  or `Unsupported`);
- residency (`full-gpu`, `partial-offload`, `host-loadable`,
  `non-interactive`, `not-loadable`, `unsupported`, or `unverified`);
- fit stage/confidence and weight/KV/runtime provenance.

Final `Good` means weights plus KV fit usable VRAM at the category context.
Host-RAM loadability and partial offload cannot produce final `Good`. Active
MoE parameters affect only compute/spill treatment and never weight residency.
Fallback metadata remains visibly fallback and cannot create stronger
confidence than the evidence supports.

## Failure handling

A failed or absent tree/config response produces fallback or unverified
evidence, not exclusion. Positive runtime incompatibility produces
`unsupported` and removes the candidate from the final recommendation. Exact
artifact or architecture evidence supersedes its provisional estimate and may
move a finalist either up or down.

Curated entries have no remote repository enrichment. They remain eligible as
explicitly unverified curated fallbacks and can never masquerade as exact.

## Presentation

`collect_model_scout_report` will build provisional groups only as an internal
shortlisting artifact. It will print, persist, and prepare from the final groups.
The cache JSON and dashboard receive the final stage plus evidence fields. CLI
and Markdown log reasons identify fallback/unverified evidence where present.

## Verification

Tests are written first and must demonstrate RED against PR #11 for:

- exact evidence downgrading a provisional `Good` and changing the winner;
- exact evidence promoting a lower provisional finalist;
- host-loadable and partial-offload results never becoming final `Good`;
- MoE active parameters never reducing residency;
- honest fallback/unverified provenance;
- the 18-finalist/36-request bound, cross-category de-duplication, and Prepare
  reuse without refetch;
- positive-evidence-only `unsupported` semantics;
- final-only JSON/dashboard/CLI/cache presentation;
- all #7, #9, and #11 behavior remaining green.

No installer tier, model default, Modelfile, preflight, release, site, private
repository, or external benchmark data is changed.

## Review follow-up hardening

The PR #12 adversarial review tightened four boundaries without changing the
approved pipeline or its request bound:

- discovery and provisional grouping preserve candidates by exact repository
  identity; normalized display names are never a pre-shortlist de-duplication
  key;
- known unsized FP8, MXFP4, NVFP4, BF16, and F16 artefacts use conservative
  storage widths, while a parsed tensor type with no defined safe width remains
  unverified rather than inheriting a Q4-shaped global estimate;
- `RemoteFinalistEvidence`, `CuratedFinalistEvidence`, and
  `FinalizedCandidate` make the final-fit boundary structural. Public
  provisional APIs have no `final=True` promotion switch, and `FinalRanking`
  validates both evidence identity and the fit context used to produce it;
- cache schema version 2 binds final results to RAM, VRAM, request parallelism,
  KV factor, and every category target context. Readers reject legacy,
  partial, malformed, mismatched, and candidate-provisional payloads. Writers
  flush a same-directory temporary file and atomically replace the cache.

The maximum remains five discovery requests plus 18 tree/config pairs: 41
requests for one Scout execution, with exact-repository de-duplication lowering
the actual total when a finalist appears in multiple categories.
