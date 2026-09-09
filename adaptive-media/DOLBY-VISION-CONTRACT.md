# Dolby Vision conversion contract

## Authority and scope

`source/src/AdaptiveMedia.App/DvConversionPlan.cs` owns the typed facts, losses,
output expectations and stable reason codes. `DvConversionPlanner.Build` is the
pure policy entry point. `tests/DolbyVisionTests` is a dependency-free deterministic
console suite matching existing repository test conventions.

Source facts reuse `MediaInfo` but do not derive DV from its HDR boolean. Existing
mpv `MediaProbe` does not classify DV. `DvEvidenceAdapter` is the execution-grade
Matroska adapter: it combines `mkvmerge -J`, FFprobe configuration/HDR evidence,
and a `dovi_tool` whole-stream RPU extraction, summary and EL demux. A first-frame
flag, filename or profile number alone is insufficient.
`Hdr10Base.Yes` is an evidence assertion, including compatible color representation
and HDR signalling, not a conclusion from PQ alone. Unknowns remain unknown.

## Initial policy

| Source -> target | Method | Explicit changes/losses |
|---|---|---|
| P7 MEL -> P8.1 | Copy compressed HEVC base, discard EL | Rewrite RPU, discard MEL material |
| P7 FEL -> P8.1 | Copy compressed HEVC base, discard EL | Rewrite RPU, discard FEL picture contribution; mandatory typed warning |
| P8.1 -> HDR10 | Copy compressed base | Remove DV RPU and configuration; dynamic metadata lost |
| P5 -> either | Future decode/process/re-encode | Base not copied; DV metadata must be removed or regenerated |
| Unknown, contradictory, non-DV, other pairs | Unsupported | No promised output |

Stream-copy policies require validated RPU, known 10-bit HEVC geometry/cadence,
explicit HDR10-compatible base and consistent PQ/BT.2020 signalling. P7 requires
MEL/FEL classification; P8.1 requires compatibility ID 1 and no EL. This is a
conservative policy, not a complete format validator. Unsupported P5 plans still
describe the required pixel method, without claiming an implemented recipe.

“Stream copy” means compressed base picture data is retained without decoding and
encoding. Container bytes, NAL framing, RPU and EL can change. It does not mean
byte-identical files or full Dolby Vision fidelity. MEL and FEL both have EL
material; FEL also carries picture reconstruction contribution that is discarded.

## Invariants

- Source + target produces identical serialized plan content; no I/O, clock or GPU probing.
- Plans have no public constructor/setters. Derived losses and FEL warning share one construction path.
- Stream copy cannot report re-encoding or useful GPU acceleration.
- Pixel processing cannot report base stream copy; acceleration is only potentially useful.
- `Supported` is policy support. `Executable` is true only for supported P7
  MEL/FEL -> P8.1 plans handled by `DvMatroskaP81Executor`; all other plans remain
  non-executable.
- Unsupported plans promise no expected output. Output expectations are not validation evidence.
- P8.1 output means profile 8 / compatibility ID 1 / RPU / no EL / HDR10 base.
- HDR10 output means no DV RPU or configuration, no EL, compatible base retained.

## Upstream checked 2026-09-09

- [dovi_tool README](https://github.com/quietvoid/dovi_tool#hevc-parsing--handling):
  mode 2 transforms RPU to P8.1; `convert --discard` drops EL; documented FFmpeg
  extraction uses video copy. These are elementary-stream primitives.
- [libdovi DoviRpu](https://github.com/quietvoid/dovi_tool/blob/main/dolby_vision/src/rpu/dovi_rpu.rs):
  `convert_to_p81` disables residual reconstruction and removes NLQ; mode 2 removes
  FEL mapping. Its P5 conversion edits RPU only, not video pixels.
- [FFmpeg dovi_rpuenc.c](https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/dovi_rpuenc.c):
  P5 uses proprietary IPTPQc2 and compatibility ID 0; P8 HDR10 uses BT.2020 NCL/PQ
  and ID 1. Therefore rewriting P5 metadata cannot make its pixels HDR10-compatible.
- [FFmpeg bitstream filters](https://ffmpeg.org/ffmpeg-bitstream-filters.html#dovi_005frpu):
  filters act without decoding; `dovi_rpu` strip removes configuration and RPU.
  Current `dovi_split` documentation describes EL/RPU separation, not P8.1 rewriting.

## Evidence and execution boundary

The real adapter accepts a supported Matroska container with exactly one video
track, and that track must be HEVC. It requires agreement between FFprobe's DV
configuration, an extracted full elementary stream parsed by `dovi_tool`, the RPU
count and the selected video's packet count, and actual EL demux evidence. HDR10
base status additionally requires 10-bit 4:2:0 HEVC, PQ, BT.2020 primaries,
BT.2020 non-constant-luminance matrix, mastering-display metadata, and
content-light metadata. Disagreement is malformed evidence, never an inferred
classification.

`DvMatroskaP81Executor` accepts only an executable planner-produced P7 -> P8.1
stream-copy/EL-discard plan. It re-probes immediately and rejects a stale or
different plan. FEL requires an explicit acknowledgement before any helper runs,
and the result always carries `FelPictureContributionLost`,
`P7FelToP81FelDiscarded`, and `FelPictureContributionNotRetained`.

Execution is a same-destination-directory transaction. The source is read-only and
SHA-256 checked before and after. A pre-existing destination is never overwritten.
`dovi_tool 2.3.3`/libdovi 3.4.0 performs mode-2 RPU conversion with EL discard;
MKVToolNix 101.0 remuxes the converted elementary stream and source container
content. Only a fully validated temporary MKV is atomically moved to the requested
path, and transaction data is cleaned on success, rejection, cancellation, or
failure.

Supported preservation is explicit: original track order; all non-video payloads
and timestamps; video timestamps and exact default duration; track language, name,
enabled/default/forced/accessibility/original/commentary flags and typed header
inventory; chapters; attachment identity and bytes; title, date, timestamp scale;
and global/track tags. The new video TrackUID may differ, so video tags are remapped.
MKVToolNix-generated statistics (`BPS`, `DURATION`, frame/byte counts and associated
`_STATISTICS_*` fields) are regenerated container data and are excluded from the
metadata-identity promise.

Promotion requires independent evidence, not helper exit codes:

- output profile 8, compatibility ID 1, validated RPU count, HDR10 base, and no EL;
- SHA-256 equality after independently removing DV metadata from both input and
  output elementary streams, proving the compressed base was not transcoded;
- byte-identical video timestamps and byte-identical non-video extracted payloads
  and timestamps;
- normalized track/header inventory, chapters, attachments and supported metadata;
- unchanged source SHA-256 and a still-absent destination at promotion time.

Any failed proof leaves no promoted output. A real regression deliberately replaces
the converted stream after a zero-exit helper result; the validator rejects it.

## Fixtures and tooling

The checked-in 259-frame MEL and FEL Matroska fixtures are reproducible structural
samples with HDR10 base video, audio, forced subtitle, chapters, attachment and
tags. Their exact upstream blobs, tool releases, SHA-256 values and licenses are in
[`tests/DolbyVisionExecutionTests/fixtures/PROVENANCE.md`](tests/DolbyVisionExecutionTests/fixtures/PROVENANCE.md).
They are not claimed to be authored commercial Dolby Vision masters or subjective
quality references.

The real gate pins dovi_tool 2.3.3 and MKVToolNix 101.0 under
`.artifacts/dv-tests`, verifies archive/fixture hashes, and requires FFprobe 7.1 on
PATH. Fixture reconstruction additionally requires FFmpeg 7.1, Git and an archive
extractor. Missing real tools are a failure, never a skipped success.

## Verification and remaining scope

Run the semantic and real-media gates with:

```powershell
dotnet run --project source/tests/AdaptiveMedia.Tests.csproj
dotnet run --project tests/DolbyVisionTests/DolbyVisionTests.csproj
pwsh -NoProfile -ExecutionPolicy Bypass -File tests/Run-DolbyVisionExecutionTests.ps1
```

The established counts are 220 existing assertions, exactly 58 planner/contract
assertions, and 29 real execution assertions with no skips.

P8.1 -> HDR10 execution, P5/pixel conversion, NVENC/libplacebo GPU conversion,
Shadow Transcode, installer changes, playback integration, and broad WPF UI remain
out of scope and non-executable.

Production integration is verified with
`dotnet build source/src/AdaptiveMedia.App/AdaptiveMedia.App.csproj --no-restore`.
No playback production files are modified by this milestone.
