# Dolby Vision Matroska Profile 7 to Profile 8.1 Execution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an evidence-backed Dolby Vision source classifier and one transactional Matroska Profile 7 MEL/FEL to Profile 8.1 executor that preserves the source, copies the HEVC base, preserves supported container content, and validates the temporary output before no-overwrite promotion.

**Architecture:** A process adapter invokes pinned, mature FFprobe, dovi_tool/libdovi, and MKVToolNix primitives with argument lists rather than a shell. The evidence adapter combines FFprobe container/HDR evidence, MKVToolNix track inventory, whole-stream dovi_tool extraction/summary, and actual EL demux evidence into the existing `DvSourceInfo`; the executor accepts only a planner-approved Profile 7→8.1 plan, extracts video/timestamps/tags, runs `dovi_tool -m 2 convert --discard`, remuxes, restores track headers/tags, and independently fingerprints the temporary output before an atomic `File.Move(..., overwrite: false)` promotion.

**Tech Stack:** .NET 10/C#, FFmpeg/FFprobe 7.1 or newer, dovi_tool 2.3.3 (libdovi 3.4.0), MKVToolNix 101.0, dependency-free console assertion suites, PowerShell fixture/tool preparation.

**Spec:** `adaptive-media/DOLBY-VISION-CONTRACT.md`

## Global Constraints

- `DvConversionPlanner.Build` remains pure and deterministic; real probing and execution live outside the planner.
- Profile 7 MEL/FEL to Profile 8.1 is the only executable conversion added.
- Profile 5, Profile 8.1→HDR10 execution, NVENC/libplacebo, Shadow Transcode, installer changes, and WPF UI work remain out of scope.
- A Profile 7 source must have whole-stream validated RPU, actual EL presence, known MEL/FEL type, Main 10 HEVC, known geometry/cadence, BT.2020 non-constant-luminance/PQ signalling, and HDR10 mastering-display plus content-light metadata.
- FEL execution requires explicit caller acknowledgement and always returns `FelPictureContributionLost`; no API path may downgrade or omit that loss.
- Source bytes are hashed before work and immediately before promotion; any change aborts promotion.
- Base-picture stream copy is proven by extracting source/output elementary streams, removing EL/RPU with dovi_tool, and requiring identical SHA-256 hashes.
- A helper's zero exit code is necessary but never sufficient: output DV state, RPU count, EL absence, base hash, timestamps, tracks, chapters, attachments, tags, flags, and selected segment metadata must independently match expectations.
- Temporary work is created beside the destination so final promotion is an atomic, no-overwrite move; cancellation/failure removes temporary artifacts and never removes or rewrites the source.
- Third-party fixtures retain exact upstream tag/commit/blob/checksum provenance and the upstream MIT notice.

---

### Task 1: Establish Reproducible MEL/FEL Matroska Fixtures

**Files:**
- Create: `adaptive-media/tests/DolbyVisionExecutionTests/fixtures/Build-DvFixtures.ps1`
- Create: `adaptive-media/tests/DolbyVisionExecutionTests/fixtures/zero-active-area.json`
- Create: `adaptive-media/tests/DolbyVisionExecutionTests/fixtures/fixture.srt`
- Create: `adaptive-media/tests/DolbyVisionExecutionTests/fixtures/chapters.txt`
- Create: `adaptive-media/tests/DolbyVisionExecutionTests/fixtures/global-tags.xml`
- Create: `adaptive-media/tests/DolbyVisionExecutionTests/fixtures/video-tags.xml`
- Create: `adaptive-media/tests/DolbyVisionExecutionTests/fixtures/attachment.txt`
- Create: `adaptive-media/tests/DolbyVisionExecutionTests/fixtures/p7-mel.mkv`
- Create: `adaptive-media/tests/DolbyVisionExecutionTests/fixtures/p7-fel.mkv`
- Create: `adaptive-media/tests/DolbyVisionExecutionTests/fixtures/PROVENANCE.md`
- Modify: `adaptive-media/.gitignore`

**Interfaces:**
- Consumes: official `quietvoid/dovi_tool` tag `2.3.3` at commit `d1abe0e27ff2c7ab3339614d06db9f8a058af6b2`, official dovi_tool Windows archive SHA-256 `37ae198f2a535c910befad39fc09c21cded76bf3ef2d5459d542e58c2c158311`, official MKVToolNix 101.0 portable archive SHA-256 `4ee52c5065e4a9c2d88462e99bceac249f07eb2d3bfe415838b6f783642c6417`.
- Produces: two small, deterministic Matroska sources with 259 Profile 7 frames, actual EL material, HDR10 base signalling, FLAC audio, SRT subtitle, two chapters, one attachment, segment title/date, global tag, and video-track tag.

- [ ] **Step 1: Write the deterministic fixture inputs and builder**

The builder must verify every downloaded archive and upstream blob before use, copy `regular_bl_start_code_4.hevc`, `regular_start_code_4.hevc`, `regular_rpu_mel.bin`, and `fel_orig.bin` from the pinned source, expand the one-frame FEL RPU to 259 frames, normalize its active-area offsets through `dovi_tool editor`, inject MEL/FEL RPUs, mux actual EL material, and produce Matroska files through `mkvmerge`. All generated work lives under ignored `adaptive-media/.artifacts/dv-tests`; only the two final MKVs and provenance files are copied into `fixtures`.

```powershell
& $DoviTool inject-rpu -i $ElHevc --rpu-in $MelRpu -o $MelEl
& $DoviTool mux --bl $BaseHevc --el $MelEl -o $MelP7
& $DoviTool editor -i $RepeatedFelRpu -j $ZeroActiveArea -o $FelRpu
& $DoviTool inject-rpu -i $ElHevc --rpu-in $FelRpu -o $FelEl
& $DoviTool mux --bl $BaseHevc --el $FelEl -o $FelP7
```

- [ ] **Step 2: Run the builder and inspect both fixtures with independent tools**

Run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File adaptive-media/tests/DolbyVisionExecutionTests/fixtures/Build-DvFixtures.ps1
```

Expected: both files are created; `dovi_tool extract-rpu` + `info --summary` reports `Profile: 7 (MEL)` and `Profile: 7 (FEL)` with 259 frames; FFprobe reports profile 7, compatibility ID 6, RPU+EL+BL, Main 10, BT.2020/PQ, mastering-display metadata, and content-light metadata.

- [ ] **Step 3: Record immutable provenance and hashes**

`PROVENANCE.md` must name the upstream license, tag, commit, source blob IDs, archive checksums, exact construction commands, intended structural purpose, and the SHA-256 of each checked-in MKV. It must state that the fixtures prove parser/executor structure, not licensed Dolby mastering or visual fidelity.

- [ ] **Step 4: Commit the fixture checkpoint**

```powershell
git add adaptive-media/.gitignore adaptive-media/tests/DolbyVisionExecutionTests/fixtures
git commit -m "test: add provenance-backed Dolby Vision MEL and FEL fixtures"
```

### Task 2: Make Only the Implemented Planner Path Executable

**Files:**
- Modify: `adaptive-media/source/src/AdaptiveMedia.App/DvConversionPlan.cs`
- Modify: `adaptive-media/source/src/AdaptiveMedia.App/DvConversionPlanner.cs`
- Modify: `adaptive-media/tests/DolbyVisionTests/Program.cs`

**Interfaces:**
- Consumes: existing immutable `DvConversionPlan` construction path.
- Produces: `DvConversionPlan.Executable == true` only for supported Profile 7 MEL/FEL→Profile 8.1 plans; all other plans retain `ExecutorNotImplemented` and `Executable == false`.

- [ ] **Step 1: Change the existing 58-assertion contract test first**

Replace the blanket `!p.Executable` check with a hand-derived expectation while keeping the total contract assertion count at 58:

```csharp
bool p7To81 = source.Profile == 7 && target == DvConversionTarget.Profile81 && p.Supported;
Check(p.Executable == p7To81, "Only implemented P7 to P8.1 plans are executable");
Check(p.Executable == !p.Codes.Contains(DvReasonCode.ExecutorNotImplemented), "Executable reason consistency");
```

Fold the second condition into the same `Check` so the count remains 58.

- [ ] **Step 2: Run the contract suite and verify RED**

Run:

```powershell
$env:DOTNET_CLI_HOME='C:\Users\jidan\AppData\Local\AdaptiveMediaDev\dotnet-home'
dotnet run --project adaptive-media/tests/DolbyVisionTests/DolbyVisionTests.csproj
```

Expected: FAIL because Profile 7 plans still report `Executable == false` and still contain `ExecutorNotImplemented`.

- [ ] **Step 3: Add one internal executor-implemented constructor fact**

Add an internal `bool executorImplemented = false` constructor parameter, store it as `Executable`, reject `executorImplemented && !supported`, and append `ExecutorNotImplemented` only when false. Pass `executorImplemented: true` only from the planner's supported Profile 7→Profile 8.1 branch. Do not add public setters or constructors.

- [ ] **Step 4: Run the 58 assertions and verify GREEN**

Expected: `PASS: 58 total Dolby Vision assertions`.

- [ ] **Step 5: Commit the planner milestone transition**

```powershell
git add adaptive-media/source/src/AdaptiveMedia.App/DvConversionPlan.cs adaptive-media/source/src/AdaptiveMedia.App/DvConversionPlanner.cs adaptive-media/tests/DolbyVisionTests/Program.cs
git commit -m "feat: mark only Profile 7 to 8.1 plans executable"
```

### Task 3: Add a Cancellable External-Tool Boundary

**Files:**
- Create: `adaptive-media/source/src/AdaptiveMedia.App/DvToolProcess.cs`
- Create: `adaptive-media/tests/DolbyVisionExecutionTests/DolbyVisionExecutionTests.csproj`
- Create: `adaptive-media/tests/DolbyVisionExecutionTests/Program.cs`

**Interfaces:**
- Produces: `IDvToolProcess.RunAsync(string executable, IReadOnlyList<string> arguments, string workingDirectory, TimeSpan timeout, CancellationToken cancellationToken)` returning `DvToolResult(int ExitCode, string Output, string Error)`; `DvToolProcess` uses `ProcessStartInfo.ArgumentList`, drains both output streams, and kills the whole process tree on timeout/cancellation.

- [ ] **Step 1: Write a failing real process-boundary test**

The assertion suite launches `dotnet --version`, requires exit code zero plus non-empty version output, then launches a long-running child command with a short cancellation token and asserts `OperationCanceledException` rather than accepting an orphaned process.

```csharp
var result = await runner.RunAsync(dotnet, ["--version"], fixtureDirectory, TimeSpan.FromSeconds(10), CancellationToken.None);
Check(result.ExitCode == 0 && result.Output.Trim().Length > 0, "Tool runner captures a real process");
```

- [ ] **Step 2: Run the new suite and verify RED**

Run:

```powershell
dotnet run --project adaptive-media/tests/DolbyVisionExecutionTests/DolbyVisionExecutionTests.csproj -- --tools <tool-directory>
```

Expected: compile failure because `IDvToolProcess`, `DvToolResult`, and `DvToolProcess` do not exist.

- [ ] **Step 3: Implement the minimal process boundary**

Use a linked timeout token, start asynchronous reads before waiting, kill `entireProcessTree: true` on either cancellation source, await process termination and both readers, and throw `TimeoutException` only when the internal timeout—not caller cancellation—wins.

- [ ] **Step 4: Run the process assertions and verify GREEN**

- [ ] **Step 5: Commit the process boundary**

```powershell
git add adaptive-media/source/src/AdaptiveMedia.App/DvToolProcess.cs adaptive-media/tests/DolbyVisionExecutionTests
git commit -m "feat: add cancellable Dolby Vision tool runner"
```

### Task 4: Implement the Whole-Stream Evidence Adapter

**Files:**
- Create: `adaptive-media/source/src/AdaptiveMedia.App/DvMatroskaEvidence.cs`
- Create: `adaptive-media/source/src/AdaptiveMedia.App/DvEvidenceAdapter.cs`
- Modify: `adaptive-media/tests/DolbyVisionExecutionTests/Program.cs`

**Interfaces:**
- Consumes: `IDvToolProcess`, explicit paths to `ffprobe`, `dovi_tool`, `mkvmerge`, and `mkvextract`.
- Produces: `DvEvidenceAdapter.ReadAsync(string sourcePath, CancellationToken)` returning `DvMatroskaEvidence` with `DvSourceInfo Source`, selected video track ID/UID, RPU frame count, video packet count, actual EL presence, HDR static-metadata evidence, source inventory, and diagnostic command evidence.

- [ ] **Step 1: Write failing MEL/FEL classification assertions against the real MKVs**

```csharp
var mel = await adapter.ReadAsync(melPath, CancellationToken.None);
Check(mel.Source is { Detection: DvDetection.Detected, Profile: 7, CompatibilityId: 6,
    EnhancementLayer: DvEnhancementLayer.Mel, Rpu: DvRpuStatus.Validated,
    Hdr10Base: DvCompatibility.Yes, BitDepth: 10 }, "Real MEL source classified");
Check(mel.RpuFrameCount == 259 && mel.VideoPacketCount == 259 && mel.EnhancementLayerPresent,
    "MEL evidence covers the complete selected stream");
```

Repeat with literal FEL expectations. Add negative assertions for non-Matroska, multiple video tracks, RPU/frame-count mismatch, missing static HDR metadata, and tool non-zero results using a focused fake `IDvToolProcess` that returns complete captured structures.

- [ ] **Step 2: Run and verify RED**

Expected: compile failure because the evidence types do not exist.

- [ ] **Step 3: Implement structured tool interrogation without parsing RPU bytes**

Required commands:

```text
mkvmerge -J <source>
ffprobe -v error -count_packets -select_streams v:<ordinal> -show_streams -of json <source>
ffprobe -v error -select_streams v:<ordinal> -show_frames -read_intervals %+#1 -of json <source>
mkvextract <source> tracks <track-id>:source.hevc
dovi_tool extract-rpu -i source.hevc -o source.rpu.bin
dovi_tool info --summary -i source.rpu.bin
dovi_tool demux --el-only source.hevc --el-out source.el.hevc
```

Parse FFprobe and MKVToolNix JSON with `System.Text.Json`; parse only dovi_tool's documented summary fields (`Frames`, `Profile`, `MEL`/`FEL`). Require all 259 RPUs to match the 259 Matroska video packets, actual EL demux success/non-empty output for Profile 7, FFprobe configuration agreement, Main 10 4:2:0, BT.2020 primaries, BT.2020 non-constant-luminance matrix, PQ transfer, mastering-display metadata, and content-light metadata. Preserve unknown/contradictory evidence as typed unknown/malformed facts so the planner rejects it.

- [ ] **Step 4: Run classification and negative assertions and verify GREEN**

- [ ] **Step 5: Commit the evidence adapter**

```powershell
git add adaptive-media/source/src/AdaptiveMedia.App/DvMatroskaEvidence.cs adaptive-media/source/src/AdaptiveMedia.App/DvEvidenceAdapter.cs adaptive-media/tests/DolbyVisionExecutionTests
git commit -m "feat: classify Dolby Vision from whole-stream evidence"
```

### Task 5: Implement Transactional Profile 7 to Profile 8.1 Execution

**Files:**
- Create: `adaptive-media/source/src/AdaptiveMedia.App/DvMatroskaP81Executor.cs`
- Modify: `adaptive-media/source/src/AdaptiveMedia.App/DvMatroskaEvidence.cs`
- Modify: `adaptive-media/tests/DolbyVisionExecutionTests/Program.cs`

**Interfaces:**
- Consumes: `DvExecutionRequest(string SourcePath, string DestinationPath, DvConversionPlan Plan, bool AcknowledgeFelLoss)` and `DvMatroskaEvidence` from the adapter.
- Produces: `DvExecutionResult` containing promoted path, source/output SHA-256, source/output `DvSourceInfo`, immutable plan losses/codes, base-picture SHA-256, validation report, and `Promoted == true` only after every check succeeds.

- [ ] **Step 1: Write failing guard and transactional-cleanup assertions**

Assert rejection before helper launch for: destination exists, source equals destination, non-Matroska, non-executable/wrong-target plan, plan/source mismatch, and FEL without acknowledgement. Use a fake tool process to force conversion failure, remux failure, validation failure, timeout, and cancellation; each must preserve source SHA-256, leave destination absent, and remove the same-directory transaction folder.

```csharp
await ExpectFailureAsync(
    () => executor.ExecuteAsync(new(felPath, outputPath, felPlan, AcknowledgeFelLoss: false), CancellationToken.None),
    "FEL execution requires explicit acknowledgement");
Check(!File.Exists(outputPath), "Unacknowledged FEL never creates output");
```

- [ ] **Step 2: Run and verify RED**

Expected: compile failure because the executor types do not exist.

- [ ] **Step 3: Implement the transaction pipeline**

The executor must:

1. Canonicalize source/destination and reject aliases or existing destination.
2. Re-probe source, rebuild the plan with `DvConversionPlanner.Build`, and require serialized semantic equality with the supplied plan.
3. Require `AcknowledgeFelLoss` for FEL and require both FEL reason codes/loss flags.
4. Hash source; create `.adaptivemedia-dv-<guid>` beside the destination.
5. Extract source video, timestamps, and tags through `mkvextract`.
6. Run `dovi_tool -m 2 convert --discard source.hevc -o converted.hevc`.
7. Remux source without video/global/track tags, add converted HEVC at the original track position with original timestamps and supported header flags, while automatically copying all audio/subtitles/buttons, chapters, and attachments.
8. Restore exact source `DefaultDuration`; rewrite only source video `TrackUID` references in extracted XML tags to the new video UID; apply all tags with `mkvpropedit`.
9. Independently validate the complete temporary MKV.
10. Re-hash source and abort if changed.
11. Atomically promote with `File.Move(tempOutput, destination, overwrite: false)`.
12. Always remove the transaction directory in `finally`.

- [ ] **Step 4: Implement independent validation assertions**

Validation must reject unless all are true:

- Output evidence is profile 8, compatibility ID 1, validated RPU, no EL, HDR10 base yes, and RPU frames equal video packets.
- `dovi_tool remove` on the source extracted HEVC and output extracted HEVC yields byte-identical SHA-256.
- Source/output `mkvextract timestamps_v2` video timestamp files are byte-identical.
- Every non-video track extracted payload and timestamp file is byte-identical.
- Track order, codec IDs, language/name, default/forced/enabled/hearing-impaired/visual-impaired/original/commentary flags, audio properties, and subtitle properties match.
- Chapters, attachment payload/metadata, custom global/track tags, container title/date/timestamp scale, and source duration match; generated statistics, muxing app, writing app, segment UID, cue positions, and container byte layout are explicitly excluded.

- [ ] **Step 5: Run guard/cleanup/validation assertions and verify GREEN**

- [ ] **Step 6: Commit the transactional executor**

```powershell
git add adaptive-media/source/src/AdaptiveMedia.App/DvMatroskaP81Executor.cs adaptive-media/source/src/AdaptiveMedia.App/DvMatroskaEvidence.cs adaptive-media/tests/DolbyVisionExecutionTests
git commit -m "feat: execute transactional Matroska Dolby Vision conversion"
```

### Task 6: Add Real MEL/FEL Execution Regressions

**Files:**
- Modify: `adaptive-media/tests/DolbyVisionExecutionTests/Program.cs`
- Create: `adaptive-media/tests/Run-DolbyVisionExecutionTests.ps1`

**Interfaces:**
- Consumes: checked-in MEL/FEL fixtures and prepared tool directory.
- Produces: an assertion count covering both real conversions, typed FEL acknowledgement/loss, byte-identical source hashes, byte-identical normalized bases, Profile 8.1 output state, stream/timestamp/container preservation, no-overwrite behavior, and cleanup.

- [ ] **Step 1: Write the real MEL execution regression**

Probe fixture, build plan, execute to a fresh temporary destination, require `Promoted`, re-probe output, and assert every validation field plus unchanged source hash. Then attempt the same destination again and require no overwrite.

- [ ] **Step 2: Run MEL regression and verify RED before final executor wiring**

Temporarily make the executor omit tag restoration; run the real test and require failure at the custom-video-tag comparison. Restore the implementation and require GREEN. This mutation proves validation—not the helper exit code—controls promotion.

- [ ] **Step 3: Write and run the FEL execution regression**

First require rejection without acknowledgement. Then execute with acknowledgement and require `FelPictureContributionLost`, `P7FelToP81FelDiscarded`, and `FelPictureContributionNotRetained` in the result while proving Profile 8.1/no EL/base hash equality. Mutation: remove the FEL loss flag from a copied validation expectation and require the assertion to fail; restore and require GREEN.

- [ ] **Step 4: Add the repeatable test entry point**

`Run-DolbyVisionExecutionTests.ps1` resolves pinned tools under `.artifacts/dv-tests`, invokes the fixture builder only when verified fixtures/tools are absent, then runs the console suite with explicit tool paths. It returns non-zero for a skipped/missing real test; real regressions never report success by skipping.

- [ ] **Step 5: Commit real execution regressions**

```powershell
git add adaptive-media/tests/DolbyVisionExecutionTests adaptive-media/tests/Run-DolbyVisionExecutionTests.ps1
git commit -m "test: prove real Dolby Vision MEL and FEL execution"
```

### Task 7: Update the Contract and Run the Full Gate

**Files:**
- Modify: `adaptive-media/DOLBY-VISION-CONTRACT.md`
- Modify: `adaptive-media/README.md`

**Interfaces:**
- Produces: operator-facing prerequisites, exact supported scope/loss language, fixture provenance, validation definition, and reproducible commands without claiming P5/GPU/UI support.

- [ ] **Step 1: Update the semantic contract from reproduced evidence**

Change only the milestone-dependent invariant: Profile 7 MEL/FEL→Profile 8.1 plans are executable because the real executor exists; other plans remain non-executable. Document explicit FEL acknowledgement, required tools/versions, Matroska-only/one-video-track constraints, supported preservation fields, excluded generated container fields, transaction semantics, and independent validation proofs.

- [ ] **Step 2: Run the complete fresh verification gate**

```powershell
$env:DOTNET_CLI_HOME='C:\Users\jidan\AppData\Local\AdaptiveMediaDev\dotnet-home'
dotnet run --project adaptive-media/source/tests/AdaptiveMedia.Tests.csproj
dotnet run --project adaptive-media/tests/DolbyVisionTests/DolbyVisionTests.csproj
pwsh -NoProfile -ExecutionPolicy Bypass -File adaptive-media/tests/Run-DolbyVisionExecutionTests.ps1
dotnet build adaptive-media/source/src/AdaptiveMedia.App/AdaptiveMedia.App.csproj --no-restore
git diff --check
git status --short
```

Expected: 220 existing assertions pass, exactly 58 contract assertions pass, all real execution assertions pass without skips, application build reports 0 warnings/0 errors, `git diff --check` is empty, and status contains only intended files.

- [ ] **Step 3: Re-read the contract and mutation-check the validators**

Confirm every output expectation in `DOLBY-VISION-CONTRACT.md` maps to an independent validation field. Mentally mutate: wrong profile, compatibility ID, EL flag, RPU count, base hash, timestamps, dropped track, changed track payload, missing chapter, missing attachment, changed tag, changed flag, changed source, pre-existing destination, and unacknowledged FEL; each must be caught by a named test.

- [ ] **Step 4: Commit documentation and final verified state**

```powershell
git add adaptive-media/DOLBY-VISION-CONTRACT.md adaptive-media/README.md
git commit -m "docs: record validated Dolby Vision execution contract"
```
