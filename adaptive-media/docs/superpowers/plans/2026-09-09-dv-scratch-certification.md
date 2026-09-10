# Dolby Vision Scratch Optimization and Certification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bound and preflight scratch use for the unchanged transactional Matroska Profile 7 to Profile 8.1 executor, prove fail-closed artifact lifetimes, and certify locally available authored Profile 7 media.

**Architecture:** Replace eager whole-container extraction with staged video validation and sequential non-video/metadata comparisons. A pure preflight calculation plus destination-volume provider gates execution, while a scratch tracker measures all executor and evidence-adapter temporary files without weakening independent validation.

**Tech Stack:** .NET 10/C#, MKVToolNix 101.0, dovi_tool 2.3.3/libdovi, FFprobe 7.1, PowerShell regression entry points.

**Spec:** `adaptive-media/docs/superpowers/specs/2026-09-09-dv-scratch-certification-design.md`

## Global Constraints

- Preserve the source byte-for-byte and re-hash it immediately before atomic promotion.
- Keep Profile 7 FEL loss explicit and acknowledgement-gated.
- Preserve independent output profile/RPU/EL, normalized-base, stream, chapter, attachment, and metadata validation.
- Treat uncertain EL demux evidence as malformed/unknown.
- Do not add P5, GPU/NVENC/libplacebo, Shadow Transcode, installer, or UI work.

---

### Task 1: Add deterministic scratch preflight

**Files:**
- Create: `adaptive-media/source/src/AdaptiveMedia.App/DvScratchPreflight.cs`
- Modify: `adaptive-media/source/src/AdaptiveMedia.App/DvMatroskaP81Executor.cs`
- Test: `adaptive-media/tests/DolbyVisionExecutionTests/Program.cs`

**Interfaces:**
- Produces: `DvScratchPreflight.Calculate(long sourceBytes, long availableBytes)` and `DvMatroskaP81Executor.Preflight(string sourcePath, string destinationPath)`.
- Produces: `DvScratchSpaceException.Report` for fail-closed execution rejection.

- [ ] Write literal boundary assertions for exact required bytes, one byte below, large-input saturation, and helper-free rejection.
- [ ] Run the execution suite and verify the assertions fail because the preflight API does not exist.
- [ ] Implement saturating arithmetic, the destination-volume free-space provider, public reporting, and the pre-helper execution gate.
- [ ] Re-run the focused assertions and verify they pass.

### Task 2: Shorten video artifact lifetimes and measure peak scratch

**Files:**
- Modify: `adaptive-media/source/src/AdaptiveMedia.App/DvEvidenceAdapter.cs`
- Modify: `adaptive-media/source/src/AdaptiveMedia.App/DvMatroskaP81Executor.cs`
- Test: `adaptive-media/tests/DolbyVisionExecutionTests/Program.cs`

**Interfaces:**
- Adds an assembly-internal evidence scratch observer while preserving `DvEvidenceAdapter.ReadAsync(string, CancellationToken)`.
- Extends `DvExecutionResult` with the preflight report and measured peak scratch bytes.

- [ ] Add a lifecycle-observing real MEL assertion that requires source video deletion before output probing, converted-video deletion after remux/tag restoration, and a measured peak no greater than the preflight artifact bound.
- [ ] Run it and verify RED against the eager current lifecycle.
- [ ] Compute the source normalized-base hash once, delete its artifact immediately, delete source video after conversion, delete converted video after remux/tag restoration, and reuse the hash in the result.
- [ ] Observe transaction plus concurrent evidence scratch at every artifact-producing boundary.
- [ ] Run the focused lifecycle test and verify GREEN.

### Task 3: Validate non-video and metadata artifacts sequentially

**Files:**
- Modify: `adaptive-media/source/src/AdaptiveMedia.App/DvMatroskaP81Executor.cs`
- Test: `adaptive-media/tests/DolbyVisionExecutionTests/Program.cs`

**Interfaces:**
- Replaces eager `ExtractAsync` dictionaries with single-artifact extraction/comparison helpers that delete consumed pairs.

- [ ] Add a real fixture assertion that detects simultaneous retained source/output non-video payloads or premature artifact deletion while still requiring every validation field.
- [ ] Run it and verify RED against eager extraction.
- [ ] Extract/compare/delete each non-video payload and timestamp pair, then chapters, attachments, and output tags; retain only source tags until tag validation.
- [ ] Re-run MEL and FEL execution tests and verify GREEN.

### Task 4: Pressure-test transactional failures

**Files:**
- Modify: `adaptive-media/tests/DolbyVisionExecutionTests/Program.cs`

**Interfaces:**
- Adds test-only process decorators for cancellation after temporary-output creation and a locked cleanup artifact during conversion failure.

- [ ] Add assertions that late cancellation leaves no final-looking output and cleanup failure cannot mask the injected conversion error.
- [ ] Run each mutation and confirm it fails when the corresponding executor guarantee is disabled.
- [ ] Restore the guarantee and verify all execution assertions pass.

### Task 5: Run complete gate and authored-media certification

**Files:**
- Modify if evidence is obtained: `adaptive-media/docs/DOLBY-VISION-P7-P81-CERTIFICATION.md`

**Interfaces:**
- Produces exact tool versions, source classifications, elapsed time, throughput, size delta, validation results, and unsupported cases without changing product scope.

- [ ] Run the 220-assertion suite, 58-assertion DV semantic suite, execution suite, app build, and `git diff --check`.
- [ ] Search only local and explicitly supplied media for eligible authored full-length Profile 7 MEL/FEL sources.
- [ ] If eligible media exists, probe/classify/preflight/execute and record the complete certification matrix; if none exists, record the exact absence and do not substitute synthetic or Profile 8.1 sources.
- [ ] Commit only optimization code, tests, and necessary documentation; push the feature branch; verify the worktree is clean.
