using AdaptiveMedia;
using System.Text.Json;
int checks = 0;
void Check(bool condition, string message) { checks++; if (!condition) throw new Exception(message); }
var video = new MediaInfo(3840, 2160, 23.976, "hevc", "pq", "bt.2020", PixelFormat: "yuv420p10le");
var mel = new DvSourceInfo(DvDetection.Detected, 7, 6, video, DvCompatibility.Yes, DvEnhancementLayer.Mel, DvRpuStatus.Validated, 10, "Validated fixture facts");
var fel = mel with { EnhancementLayer = DvEnhancementLayer.Fel };
var p81 = mel with { Profile = 8, CompatibilityId = 1, EnhancementLayer = DvEnhancementLayer.None };
var p5 = mel with { Profile = 5, CompatibilityId = 0, Hdr10Base = DvCompatibility.No, EnhancementLayer = DvEnhancementLayer.None };
var m = DvConversionPlanner.Build(mel, DvConversionTarget.Profile81);
Check(m.Supported && m.BaseVideoCopied && !m.PixelsReencoded, "MEL copies base");
Check(m.RpuAction == DvRpuAction.RewriteToProfile81 && m.EnhancementLayerAction == DvEnhancementLayerAction.Discard, "MEL rewrite/discard");
Check(m.ExpectedOutput is { Profile: 8, CompatibilityId: 1, EnhancementLayer: DvEnhancementLayer.None }, "P81 output contract");
var f = DvConversionPlanner.Build(fel, DvConversionTarget.Profile81);
Check(f.Supported && f.Losses.HasFlag(DvLossClassification.FelPictureContributionLost), "FEL explicit loss");
Check(f.Codes.Contains(DvReasonCode.FelPictureContributionNotRetained), "FEL warning mandatory");
var h = DvConversionPlanner.Build(p81, DvConversionTarget.Hdr10);
Check(h.Supported && h.BaseVideoCopied && h.RpuAction == DvRpuAction.Remove, "HDR10 metadata removal");
Check(h.Losses.HasFlag(DvLossClassification.DolbyVisionMetadataLost), "DV metadata loss");
Check(h.ExpectedOutput is { DolbyVision: false, Profile: null, RpuPresent: false }, "HDR10 output contract");
foreach (var target in Enum.GetValues<DvConversionTarget>()) {
    var p = DvConversionPlanner.Build(p5, target);
    Check(!p.Supported && !p.Executable && p.Method == DvConversionMethod.DecodeProcessReencode, "P5 future pixel pipeline");
    Check(p.PixelsReencoded && !p.BaseVideoCopied && p.Acceleration == DvAccelerationRelevance.PotentiallyUsefulForPixelPipeline, "P5 pixel semantics");
}
foreach (var source in new[] {
    mel with { EnhancementLayer = DvEnhancementLayer.Unknown },
    mel with { Hdr10Base = DvCompatibility.Unknown },
    mel with { Hdr10Base = DvCompatibility.No },
    mel with { Rpu = DvRpuStatus.Unknown }, mel with { Rpu = DvRpuStatus.Malformed },
    mel with { Profile = null }, mel with { CompatibilityId = 1 },
    mel with { Detection = DvDetection.NotDetected },
    mel with { Detection = DvDetection.Unknown }, mel with { BitDepth = null },
    mel with { BaseVideo = video with { Transfer = "hlg" } },
    mel with { BaseVideo = video with { Fps = double.NaN } },
    p81 with { CompatibilityId = null }, p81 with { EnhancementLayer = DvEnhancementLayer.Fel }
}) Check(!DvConversionPlanner.Build(source, DvConversionTarget.Profile81).Supported, "Insufficient/conflicting source rejected");
foreach (var source in new[] { mel, fel, p81, p5, mel with { Profile = null } })
foreach (var target in Enum.GetValues<DvConversionTarget>()) {
    var p = DvConversionPlanner.Build(source, target);
    Check(JsonSerializer.Serialize(p) == JsonSerializer.Serialize(DvConversionPlanner.Build(source with { }, target)), "Deterministic value-equivalent input");
    bool p7To81 = source.Profile == 7 && target == DvConversionTarget.Profile81 && p.Supported;
    Check(p.Executable == p7To81 && p.Executable == !p.Codes.Contains(DvReasonCode.ExecutorNotImplemented), "Only implemented P7 to P8.1 plans are executable");
    if (p.Method is DvConversionMethod.StreamCopyMetadataRewrite or DvConversionMethod.StreamCopyEnhancementLayerDiscard)
        Check(p.BaseVideoCopied && !p.PixelsReencoded && p.Acceleration == DvAccelerationRelevance.NotUseful, "Stream-copy invariant");
    if (p.EnhancementLayerAction == DvEnhancementLayerAction.Discard && source.EnhancementLayer == DvEnhancementLayer.Fel)
        Check(p.Losses.HasFlag(DvLossClassification.FelPictureContributionLost) && p.Codes.Contains(DvReasonCode.FelPictureContributionNotRetained), "All FEL discard plans warn");
}
Check(!DvConversionPlanner.Build(mel, (DvConversionTarget)99).Supported, "Unknown target rejected");
Console.WriteLine($"PASS: {checks} Dolby Vision assertions");

// Stable reasons are part of the contract, not just explanatory text.
Check(m.Codes.Contains(DvReasonCode.P7MelToP81StreamCopy), "MEL reason");
Check(f.Codes.Contains(DvReasonCode.P7FelToP81FelDiscarded) && f.BaseVideoCopied && !f.PixelsReencoded, "FEL copy reason");
Check(!m.Losses.HasFlag(DvLossClassification.FelPictureContributionLost), "MEL is not guessed FEL");
Check(DvConversionPlanner.Build(mel with { Hdr10Base = DvCompatibility.Unknown }, DvConversionTarget.Profile81).Codes.Contains(DvReasonCode.BaseHdr10CompatibilityUnknown), "Unknown base reason");
Check(DvConversionPlanner.Build(mel with { EnhancementLayer = DvEnhancementLayer.Unknown }, DvConversionTarget.Profile81).Codes.Contains(DvReasonCode.EnhancementLayerUnknown), "Unknown EL reason");
var nonDv = new DvSourceInfo(DvDetection.NotDetected, null, null, video, DvCompatibility.Yes, DvEnhancementLayer.None, DvRpuStatus.Absent, 10);
Check(!DvConversionPlanner.Build(nonDv, DvConversionTarget.Hdr10).Supported, "Ordinary HDR10 never becomes DV");
Check(typeof(DvConversionPlan).GetConstructors().Length == 0 && typeof(DvConversionPlan).GetProperties().All(p => p.SetMethod is null), "Plans cannot be externally constructed/mutated to erase warnings");
Console.WriteLine($"PASS: {checks} total Dolby Vision assertions");
