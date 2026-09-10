# Dolby Vision Scratch-Space Certification Design

## Scope

Reduce peak scratch use for the existing transactional Matroska Profile 7 to Profile 8.1 executor without changing its conversion contract. Add a deterministic preflight and lifecycle regressions, then certify against locally available authored Profile 7 titles if any exist. Profile 5, GPU conversion, UI, installer, and unrelated application work remain out of scope.

## Current measured lifecycle

The checked-in real-media regression was sampled every 20 ms in a clean process at commit `3f723acbf77bd54a267d776032b07083b412821a`. It passed 29 assertions. The largest observed transaction directory was 863,624 bytes for a 256,843-byte MEL source (3.362x). The largest evidence-adapter directory was 355,225 bytes (1.383x that source). Sampling can miss short-lived files, so the safety model below is derived from the code's simultaneous live artifacts rather than treating the sample as an upper bound.

| Artifact | Maximum observed bytes | Created by | Last consumer in current code | Safe deletion point |
|---|---:|---|---|---|
| Evidence `source.hevc` | 136,586 | `mkvextract tracks` | `dovi_tool demux --el-only` | After EL classification |
| Evidence `source.rpu.bin` | 99,974 | `dovi_tool extract-rpu` | `dovi_tool info --summary` | After summary parse |
| Evidence `source.el.hevc` | 118,665 | `dovi_tool demux --el-only` | Non-empty-file classification | Immediately after classification |
| Source track payloads | 144,408 largest non-video; 136,586 video | eager `ExtractAsync` | validation; source video is normalized a third time for the result | After each payload comparison; source video after conversion plus first normalized hash |
| Source timestamps | 1,582 largest | eager `ExtractAsync` | remux for video; validation for all tracks | After the corresponding comparison |
| Source chapters/tags/attachments | 2,961 / 1,250 / 48 | eager `ExtractAsync` | remux/tag rewrite and validation | After corresponding validation |
| `converted-video.hevc` | 95,917 | `dovi_tool convert` | `mkvmerge` remux | Immediately after remux and tag restoration |
| `validated-output.mkv` | 257,757 | `mkvmerge` | final SHA-256 and atomic promotion | Atomic promotion only after every validation |
| Output track payloads | 144,408 largest non-video; 95,917 video | eager `ExtractAsync` | validation | After each payload comparison |
| Output timestamps/chapters/tags/attachments | 1,582 / 1,250 / 878 / 48 | eager `ExtractAsync` | validation | After corresponding validation |
| `source-base.hevc` | 18,173 | `dovi_tool remove` | SHA-256 comparison | Immediately after hashing |
| `output-base.hevc` | 18,173 | `dovi_tool remove` | SHA-256 comparison | Immediately after hashing |
| `result-base.hevc` | 18,173 | redundant third `dovi_tool remove` | result hash | Remove operation entirely; reuse the independently computed source-base hash |

Let `S` be source-container bytes, `O` the temporary output, `V` extracted source video, `C` converted/output video, `B` normalized base video, and `N` all eagerly extracted non-video and metadata payloads. The current transaction's code-derived worst live set is approximately `S-extracted + C + O + O-extracted + 3B`, which approaches `7S` for a single-layer-dominant source. The evidence prepass is separate and approaches `2S`.

## Optimized lifecycle

Keep only source video, video timestamps, and source tags long enough to convert and remux. Compute and retain the source normalized-base SHA-256, not its file. Delete source video after conversion, delete converted video after remux/tag restoration, and remove the redundant third normalization. Validate output video and normalized base next, then validate every non-video payload, timestamp, chapter document, attachment, and tag pair sequentially, deleting each pair after comparison. The temporary Matroska output remains until final source re-hash and atomic promotion.

The resulting conservative simultaneous-artifact bound is `3S + output-overhead`: either output plus an output video and normalized base, or output plus one source/output non-video pair. The evidence prepass remains bounded by `2S`. No validation result is reused across different source hashes, and the final source hash remains the last operation before promotion.

With this lifecycle implemented, instrumented execution measured 516,622 bytes for the 256,843-byte MEL fixture (2.011x) and 509,906 bytes for the 297,515-byte FEL fixture (1.714x). These measurements include concurrent evidence-adapter and transaction files at every completed artifact-producing boundary; the conservative preflight formula, not the fixture ratio, remains the acceptance bound for larger inputs.

## Preflight contract

Preflight reports source bytes, non-output temporary allowance (`2S`), output allowance (`S + max(64 MiB, ceil(S/100))`), safety margin (`max(1 GiB, ceil(S/20))`), total required free bytes, currently available bytes on the destination volume, pass/fail, and a human-readable reason. Arithmetic saturates at `long.MaxValue`; exact-bound availability passes and one byte below fails. Execution calls the same public preflight before source evidence extraction and throws a typed exception carrying the report on failure.

The 64 MiB/1% output allowance covers Matroska remux overhead without assuming the output is smaller merely because FEL is discarded. The safety margin is not claimed as artifact use; it reserves room for filesystem/tool variance and concurrent writes.

## Failure and validation invariants

- Tool success never substitutes for independently proven profile 8.1, RPU/frame parity, and no EL.
- Source/output normalized bases remain hash-identical.
- Source bytes are hashed before helpers and immediately before promotion.
- Track payloads, timestamps, order, flags, chapters, attachments, tags, title, date, duration, and timestamp scale remain validated.
- Unknown or failed EL demux remains fail-closed.
- Cancellation or any validation failure leaves no destination-looking file.
- Cleanup failure cannot replace the primary conversion error.
- The output stays inside a same-directory transaction until atomic promotion.

## Certification gate

After focused tests pass, run 220 existing assertions, 58 Dolby Vision semantic assertions, all execution assertions, the application build, and `git diff --check`. Only then search local or explicitly supplied media for full-length authored Profile 7 MEL/FEL titles. Do not download copyrighted media. If none are available, report authored Profile 7 as unverified rather than treating Profile 8.1 titles or synthetic fixtures as substitutes.
