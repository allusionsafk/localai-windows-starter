namespace AdaptiveMedia;

public static class DvConversionPlanner
{
    public static DvConversionPlan Build(DvSourceInfo source, DvConversionTarget target)
    {
        ArgumentNullException.ThrowIfNull(source);
        DvConversionPlan Reject(DvReasonCode code, string text) => new(source, target, false,
            DvConversionMethod.Unsupported, DvRpuAction.Unknown, DvEnhancementLayerAction.Unknown, code, text);
        if (!Enum.IsDefined(target)) return Reject(DvReasonCode.UnsupportedTargetOrProfile, "Unknown conversion target.");
        if (source.Detection == DvDetection.NotDetected) return Reject(DvReasonCode.NotDolbyVision, "Source is not classified as Dolby Vision.");
        if (source.Detection != DvDetection.Detected || source.Profile is null)
            return Reject(DvReasonCode.SourceClassificationUnknown, "Dolby Vision classification is incomplete.");
        var video = source.BaseVideo;
        if (video is null || !video.Known || !double.IsFinite(video.Fps) || video.Fps <= 0 ||
            video.Codec != "hevc" || source.BitDepth != 10 ||
            !Enum.IsDefined(source.Hdr10Base) || !Enum.IsDefined(source.EnhancementLayer) ||
            source.CompatibilityId is < 0 or > 15)
            return Reject(DvReasonCode.InvalidSourceFacts, "Base HEVC characteristics are insufficient or inconsistent.");
        if (source.Rpu != DvRpuStatus.Validated)
            return Reject(DvReasonCode.RpuNotValidated, "Whole-stream RPU validation is required.");
        if (source.Profile == 5)
        {
            if (source.EnhancementLayer != DvEnhancementLayer.None || source.Hdr10Base == DvCompatibility.Yes || source.CompatibilityId is not (null or 0))
                return Reject(DvReasonCode.InvalidSourceFacts, "Profile 5 facts conflict with its non-HDR10 base.");
            return new(source, target, false, DvConversionMethod.DecodeProcessReencode,
                target == DvConversionTarget.Hdr10 ? DvRpuAction.Remove : DvRpuAction.RegenerateAfterPixelProcessing,
                DvEnhancementLayerAction.None, DvReasonCode.P5RequiresPixelPipeline,
                "Profile 5 requires color processing and video re-encoding. Pixel pipeline and output metadata policy are unimplemented.");
        }
        if (source.Profile is not (7 or 8)) return Reject(DvReasonCode.UnsupportedTargetOrProfile, "Source profile is outside the conversion policy.");
        if (source.Hdr10Base == DvCompatibility.Unknown)
            return Reject(DvReasonCode.BaseHdr10CompatibilityUnknown, "HDR10 base compatibility has not been established.");
        if (source.Hdr10Base != DvCompatibility.Yes)
            return Reject(DvReasonCode.BaseNotHdr10Compatible, "This policy requires an HDR10-compatible base.");
        if (video.Transfer is not ("pq" or "smpte2084") || video.Primaries is not ("bt.2020" or "bt2020"))
            return Reject(DvReasonCode.InvalidSourceFacts, "HDR10 compatibility conflicts with base color signalling.");
        if (source.Profile == 7)
        {
            if (source.CompatibilityId is not (null or 6)) return Reject(DvReasonCode.InvalidSourceFacts, "Profile 7 compatibility ID is inconsistent.");
            if (source.EnhancementLayer == DvEnhancementLayer.Unknown)
                return Reject(DvReasonCode.EnhancementLayerUnknown, "MEL/FEL classification is required; it is not inferred from profile 7.");
            if (source.EnhancementLayer is not (DvEnhancementLayer.Mel or DvEnhancementLayer.Fel))
                return Reject(DvReasonCode.InvalidSourceFacts, "Profile 7 requires classified enhancement-layer material.");
            if (target != DvConversionTarget.Profile81) return Reject(DvReasonCode.UnsupportedTargetOrProfile, "Direct profile 7 to HDR10 is outside this initial policy.");
            return new(source, target, true, DvConversionMethod.StreamCopyEnhancementLayerDiscard,
                DvRpuAction.RewriteToProfile81, DvEnhancementLayerAction.Discard,
                source.EnhancementLayer == DvEnhancementLayer.Fel ? DvReasonCode.P7FelToP81FelDiscarded : DvReasonCode.P7MelToP81StreamCopy,
                "Copy compressed base video, rewrite RPU for profile 8.1, and discard the profile 7 enhancement layer. This is not a full-fidelity claim.");
        }
        if (source.CompatibilityId != 1 || source.EnhancementLayer != DvEnhancementLayer.None)
            return Reject(DvReasonCode.InvalidSourceFacts, "Profile 8.1 requires compatibility ID 1 and no enhancement layer.");
        if (target != DvConversionTarget.Hdr10) return Reject(DvReasonCode.UnsupportedTargetOrProfile, "Already-profile-8.1 pass-through is outside the conversion policy.");
        return new(source, target, true, DvConversionMethod.StreamCopyMetadataRewrite, DvRpuAction.Remove,
            DvEnhancementLayerAction.None, DvReasonCode.P81ToHdr10MetadataRemoved,
            "Copy the HDR10-compatible base and remove DV RPU and container configuration. Dolby Vision dynamic metadata is lost.");
    }
}
