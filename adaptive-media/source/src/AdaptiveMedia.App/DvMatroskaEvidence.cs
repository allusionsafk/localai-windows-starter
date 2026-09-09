using System.Collections.Immutable;

namespace AdaptiveMedia;

public sealed record DvToolPaths(string Ffprobe, string DoviTool, string MkvMerge,
    string MkvExtract, string MkvPropEdit);

public sealed record DvTrackInventory(
    int Id,
    ulong Uid,
    string Type,
    string CodecId,
    string? Language,
    string? LanguageIetf,
    string? Name,
    bool Default,
    bool Forced,
    bool Enabled,
    bool HearingImpaired,
    bool VisualImpaired,
    bool Original,
    bool Commentary,
    long? DefaultDuration,
    string? PixelDimensions,
    string? DisplayDimensions,
    int? AudioChannels,
    int? AudioBitsPerSample,
    double? AudioSamplingFrequency,
    bool TextSubtitles);

public sealed record DvAttachmentInventory(int Id, ulong Uid, string FileName,
    string ContentType, string Description, long Size);

public sealed record DvMatroskaInventory(
    ImmutableArray<DvTrackInventory> Tracks,
    ImmutableArray<DvAttachmentInventory> Attachments,
    int ChapterEntries,
    int GlobalTagEntries,
    string? Title,
    string? DateUtc,
    long? DurationNanoseconds,
    long? TimestampScale);

public sealed record DvMatroskaEvidence(
    string SourcePath,
    DvSourceInfo Source,
    int VideoTrackId,
    ulong VideoTrackUid,
    int RpuFrameCount,
    int VideoPacketCount,
    bool EnhancementLayerPresent,
    bool StaticHdrMetadata,
    DvMatroskaInventory Inventory,
    string EvidenceSummary);

public sealed class DvEvidenceException(string message) : IOException(message);
