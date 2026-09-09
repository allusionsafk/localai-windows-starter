using System.Collections.Immutable;

namespace AdaptiveMedia;

public enum DvDetection { Unknown, NotDetected, Detected }
public enum DvCompatibility { Unknown, No, Yes }
public enum DvEnhancementLayer { Unknown, None, Mel, Fel }
public enum DvRpuStatus { Unknown, Absent, PresentUnvalidated, Validated, Malformed }
public enum DvConversionTarget { Profile81, Hdr10 }
public enum DvConversionMethod { Unsupported, StreamCopyMetadataRewrite, StreamCopyEnhancementLayerDiscard, DecodeProcessReencode }
public enum DvAccelerationRelevance { UnknownUnsupported, NotUseful, PotentiallyUsefulForPixelPipeline }
public enum DvRpuAction { Unknown, RewriteToProfile81, Remove, RegenerateAfterPixelProcessing }
public enum DvEnhancementLayerAction { Unknown, None, Discard }
[Flags]
public enum DvLossClassification
{
    Unknown = 1, BaseVideoCopied = 2, VideoReencoded = 4, DolbyVisionMetadataChanged = 8,
    DolbyVisionMetadataLost = 16, EnhancementLayerDiscarded = 32, FelPictureContributionLost = 64
}
// Names and values are stable diagnostics/protocol identifiers; append rather than renumber.
public enum DvReasonCode
{
    SourceClassificationUnknown = 0, NotDolbyVision = 1, InvalidSourceFacts = 2,
    RpuNotValidated = 3, BaseHdr10CompatibilityUnknown = 4, BaseNotHdr10Compatible = 5,
    EnhancementLayerUnknown = 6, UnsupportedTargetOrProfile = 7,
    P7MelToP81StreamCopy = 8, P7FelToP81FelDiscarded = 9,
    FelPictureContributionNotRetained = 10, P81ToHdr10MetadataRemoved = 11,
    P5RequiresPixelPipeline = 12, ExecutorNotImplemented = 13
}

/// <summary>Probe evidence, not inferred from a filename or from MediaInfo.IsHdr.
/// Validated RPU and EL classification must describe the whole selected video stream.</summary>
public sealed record DvSourceInfo(DvDetection Detection, int? Profile, int? CompatibilityId,
    MediaInfo BaseVideo, DvCompatibility Hdr10Base = DvCompatibility.Unknown,
    DvEnhancementLayer EnhancementLayer = DvEnhancementLayer.Unknown,
    DvRpuStatus Rpu = DvRpuStatus.Unknown, int? BitDepth = null, string? Evidence = null);

public sealed record DvExpectedOutput(bool DolbyVision, int? Profile, int? CompatibilityId,
    bool RpuPresent, DvEnhancementLayer EnhancementLayer, DvCompatibility Hdr10Base);

/// <summary>Immutable policy result. Only the planner constructs plans; no public init setters.
/// Supported means a defined stream-copy policy, not runtime availability or a validated file.</summary>
public sealed class DvConversionPlan
{
    internal DvConversionPlan(DvSourceInfo source, DvConversionTarget target, bool supported,
        DvConversionMethod method, DvRpuAction rpu, DvEnhancementLayerAction el,
        DvReasonCode reason, string explanation)
    {
        Source = source; Target = target; Supported = supported; Method = method;
        RpuAction = rpu; EnhancementLayerAction = el;
        BaseVideoCopied = method is DvConversionMethod.StreamCopyMetadataRewrite or DvConversionMethod.StreamCopyEnhancementLayerDiscard;
        PixelsReencoded = method == DvConversionMethod.DecodeProcessReencode;
        Acceleration = BaseVideoCopied ? DvAccelerationRelevance.NotUseful : PixelsReencoded
            ? DvAccelerationRelevance.PotentiallyUsefulForPixelPipeline : DvAccelerationRelevance.UnknownUnsupported;
        Losses = BaseVideoCopied ? DvLossClassification.BaseVideoCopied : PixelsReencoded ? DvLossClassification.VideoReencoded : DvLossClassification.Unknown;
        if (rpu == DvRpuAction.Remove) Losses |= DvLossClassification.DolbyVisionMetadataLost;
        if (rpu is DvRpuAction.RewriteToProfile81 or DvRpuAction.RegenerateAfterPixelProcessing) Losses |= DvLossClassification.DolbyVisionMetadataChanged;
        var codes = ImmutableArray.CreateBuilder<DvReasonCode>();
        codes.Add(reason);
        if (el == DvEnhancementLayerAction.Discard)
        {
            Losses |= DvLossClassification.EnhancementLayerDiscarded;
            if (source.EnhancementLayer == DvEnhancementLayer.Fel)
            {
                Losses |= DvLossClassification.FelPictureContributionLost;
                codes.Add(DvReasonCode.FelPictureContributionNotRetained);
                explanation += " FEL picture contribution will not be retained.";
            }
        }
        codes.Add(DvReasonCode.ExecutorNotImplemented);
        Codes = codes.ToImmutable(); Explanation = explanation;
        ExpectedOutput = supported ? target == DvConversionTarget.Profile81
            ? new(true, 8, 1, true, DvEnhancementLayer.None, DvCompatibility.Yes)
            : new(false, null, null, false, DvEnhancementLayer.None, DvCompatibility.Yes) : null;
    }
    public DvSourceInfo Source { get; }
    public DvConversionTarget Target { get; }
    public bool Supported { get; }
    public bool Executable => false; // No runtime executor/capability validation in this milestone.
    public DvConversionMethod Method { get; }
    public bool BaseVideoCopied { get; }
    public bool PixelsReencoded { get; }
    public DvRpuAction RpuAction { get; }
    public DvEnhancementLayerAction EnhancementLayerAction { get; }
    public DvLossClassification Losses { get; }
    public DvAccelerationRelevance Acceleration { get; }
    public ImmutableArray<DvReasonCode> Codes { get; }
    public string Explanation { get; }
    public DvExpectedOutput? ExpectedOutput { get; }
}
