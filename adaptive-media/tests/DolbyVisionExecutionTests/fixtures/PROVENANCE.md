# Dolby Vision execution fixture provenance

These are synthetic structural regression fixtures, not commercial media and not
licensed Dolby mastering samples. They prove that the mature upstream parsers see
complete Profile 7 MEL/FEL streams and that the executor preserves/copies the
declared structures. They do not claim perceptual or mastering fidelity.

## Upstream source

- Project: `quietvoid/dovi_tool`
- Release/tag: `2.3.3`
- Git commit: `d1abe0e27ff2c7ab3339614d06db9f8a058af6b2`
- License: MIT; the full upstream notice is retained in `UPSTREAM-LICENSE.txt`.
- Official Windows archive SHA-256:
  `37ae198f2a535c910befad39fc09c21cded76bf3ef2d5459d542e58c2c158311`

Pinned Git blobs used by `Build-DvFixtures.ps1`:

| Path | Git blob |
|---|---|
| `assets/hevc_tests/regular_bl_start_code_4.hevc` | `29c8ecaed93dd869b961e674b92a1d390f721410` |
| `assets/hevc_tests/regular_start_code_4.hevc` | `3b9dd1cd65b5a45411a8e7585d6172dc37246a68` |
| `assets/hevc_tests/regular_rpu_mel.bin` | `5eefd4a3da6496b7a884a3e829a3bc19d0b89cf2` |
| `assets/tests/fel_orig.bin` | `a7926febb39043d938ebc49dce0a4c043b5b32f0` |

The upstream base is a 259-frame, 256×144 Main 10 HEVC stream with BT.2020
non-constant-luminance/PQ signalling plus mastering-display and content-light
SEIs. The upstream enhancement stream has the same frame count and geometry.

## Construction

The builder verifies every archive/blob, expands the one-frame FEL RPU to 259
frames, resets only its active-area offsets with `dovi_tool editor`, injects the
MEL/FEL RPU into the enhancement stream, and uses `dovi_tool mux` to interleave
actual BL+EL+RPU access units. MKVToolNix 101.0 then creates deterministic
Matroska containers with FLAC audio, SRT subtitles, two chapters, an attachment,
track names/flags, a segment title/date, a global tag, and a video-track tag.

`dovi_tool extract-rpu` plus `info --summary` validates all 259 RPUs after muxing.
FFprobe 7.1 independently reports Profile 7, compatibility ID 6, BL/RPU/EL
presence, Main 10, BT.2020/PQ, mastering-display, and content-light evidence.

Build command:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Build-DvFixtures.ps1
```

## Checked-in fixture hashes

| File | SHA-256 |
|---|---|
| `p7-mel.mkv` | `76717a9dd5cc11c5774528ee8805ae615031bdbc321e91eed36ce74b5a4de21d` |
| `p7-fel.mkv` | `80e476b5f1d9ed105f9113d2b77412fe19ee9b7cb2548c4382dffa48c756013f` |

Re-running the builder with the pinned tool versions and identical inputs
reproduces both hashes byte-for-byte.
