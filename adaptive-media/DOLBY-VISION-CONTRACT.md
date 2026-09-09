# Dolby Vision conversion contract

## Authority and scope

`source/src/AdaptiveMedia.App/DvConversionPlan.cs` owns the typed facts, losses,
output expectations and stable reason codes. `DvConversionPlanner.Build` is the
pure policy entry point. `tests/DolbyVisionTests` is a dependency-free deterministic
console suite matching existing repository test conventions.

Source facts reuse `MediaInfo` but do not derive DV from its HDR boolean. Existing
mpv `MediaProbe` does not classify DV. A future probe must validate the selected
whole video stream using mature upstream parsers, including RPU validity and EL
type; a first-frame flag, filename or profile number alone is insufficient.
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
- `Supported` is policy support. `Executable` is false for EVERY plan until a real executor exists.
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

## Verification and next milestone

Baseline: existing `dotnet run --project adaptive-media/source/tests` passed 220
assertions (local named-pipe access required). DV tests were introduced before
production types, failed for missing types, then passed 58 assertions.
Run: `dotnet run --project adaptive-media/tests/DolbyVisionTests`.

P7 execution is NOT implemented. Stretch assessment found FFmpeg 7.1-full_build-
www.gyan.dev on PATH (`dovi_rpu`, no `dovi_split`), no dovi_tool on PATH, no checked-in
HEVC/MKV conversion fixtures, and no whole-stream DV probe. An elementary-stream
round trip cannot yet establish container timestamp/stream/attachment preservation
or independently prove unchanged base picture data. Implementing those pieces is
larger than a trustworthy stretch; no partial executor is shipped.

Next for Sol High: add a whole-stream evidence adapter and licensed MEL/FEL fixtures,
pin an upstream converter, then implement ONE Matroska-only transactional executor.
Gate it on this planner; validate profile, RPU/EL, base coded-picture identity,
timestamps, inventory, chapters, tags and flags before atomic no-overwrite promotion.
Test cancellation/failure cleanup and unchanged source hashes. Keep P5 execution,
GPU transcoding, playback and WPF redesign out of scope.

Production integration: `dotnet build adaptive-media/source/src/AdaptiveMedia.App/AdaptiveMedia.App.csproj`
passed with 0 warnings / 0 errors after allowing NuGet restore access.
`git diff --check` passed. No playback production files were modified.
