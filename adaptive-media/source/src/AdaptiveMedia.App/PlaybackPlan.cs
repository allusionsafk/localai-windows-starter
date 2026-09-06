using System.Collections.Immutable;
using System.Globalization;

namespace AdaptiveMedia;

public sealed record MediaInfo(int Width = 0, int Height = 0, double Fps = 0,
    string Codec = "unknown", string Transfer = "unknown", string Primaries = "unknown",
    string AudioCodec = "unknown", string PixelFormat = "unknown", double Aspect = 0)
{
    public bool IsHdr => Transfer is "pq" or "hlg";
    public bool IsKnownSdr => Transfer is "bt.1886" or "srgb" or "gamma1.8" or "gamma2.0" or "gamma2.2" or "gamma2.4" or "gamma2.6" or "gamma2.8" or "linear";
    public bool Known => Width > 0 && Height > 0;
}
public sealed record PlaybackTarget(int Width, int Height, int Screen = 0, bool Fullscreen = false, bool HdrEnabled = false);
public sealed record PlaybackCapabilities(bool Nvidia, bool Vpp, string? NvidiaAdapter = null, bool Rtx = false);
public sealed record PlaybackPlan(string Executable, ImmutableArray<string> Arguments, PlaybackOptions Requested,
    MediaInfo Source, PlaybackTarget Target, string Renderer, bool RtxSrConstructed, bool RtxHdrConstructed,
    double Scale, ImmutableArray<string> Reasons, string PipeName)
{
    public string ArgumentVectorSha256 => Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(
        System.Text.Encoding.UTF8.GetBytes(string.Join('\0', Arguments))));
    public string Summary => $"{(Source.Known ? $"{Source.Width} × {Source.Height}" : "Source dimensions unknown")} · {(Source.IsHdr ? "HDR" : "SDR / unspecified")}\n" +
        (RtxSrConstructed ? $"RTX SR processing requested at {Scale:0.####}×" : Requested.UpscaleMode is "HighQuality" or "Automatic" or "RtxVsr" ? "High quality scaling" : "Standard scaling") +
        $" · {Requested.MotionMode switch { "Gentle" => "Gentle motion", "Smooth" => "Smooth motion", _ => "Native cadence" }} · PCM audio" +
        (Reasons.IsEmpty ? "" : "\n" + string.Join("\n", Reasons));
}

public static class PlaybackPlanBuilder
{
    public static double FitScale(MediaInfo source, PlaybackTarget target)
    {
        if (!source.Known || target.Width <= 0 || target.Height <= 0) return 1;
        // VPP scales coded pixels uniformly. Leave anamorphic/rotated sources to libplacebo.
        if (source.Aspect > 0 && Math.Abs(source.Aspect - (double)source.Width / source.Height) > 0.015) return 1;
        return Math.Min((double)target.Width / source.Width, (double)target.Height / source.Height);
    }

    public static PlaybackPlan Build(string executable, string configDir, IReadOnlyList<string> items,
        PlaybackOptions options, MediaInfo source, PlaybackTarget target, PlaybackCapabilities capabilities,
        string pipeName, bool bitstreamRequested = false, bool streamHelperAvailable = true)
    {
        if (items.Count == 0) throw new ArgumentException("Choose at least one media file.");
        if (items.Any(x => string.IsNullOrWhiteSpace(x) || x.IndexOfAny(['\0', '\r', '\n']) >= 0))
            throw new ArgumentException("A media path contains an unsupported control character.");
        if (!new[] { "Automatic", "Reference", "Enhanced", "Compatibility" }.Contains(options.Profile) ||
            !new[] { "Off", "Automatic", "HighQuality", "RtxVsr" }.Contains(options.UpscaleMode) ||
            !new[] { "Off", "Gentle", "Smooth" }.Contains(options.MotionMode) ||
            !new[] { "Legacy", "Off", "Gentle", "Normal", "Strong", "Automatic" }.Contains(options.CleanupMode))
            throw new ArgumentException("A playback setting is unavailable. Reset it in Settings.");
        var reasons = ImmutableArray.CreateBuilder<string>();
        if (options.AutoHdrSwitch && items.Count > 1) reasons.Add("Windows HDR is preserved for playlists because later items may use different color formats.");
        double scale = FitScale(source, target);
        bool rtxRequested = options.UpscaleMode == "RtxVsr";
        bool compatible = options.Profile == "Compatibility";
        bool eligible = capabilities.Nvidia && capabilities.Rtx && capabilities.Vpp && !compatible;
        bool sr = rtxRequested && eligible && source.Known && scale > 1.001 && scale <= 8;
        bool hdr = options.RtxHdr && eligible && source.Known && source.IsKnownSdr && target.HdrEnabled;
        bool rtxLane = eligible && (rtxRequested || hdr);
        if (rtxRequested && !sr) reasons.Add(!eligible ? "No compatible RTX processing path is available; using conventional scaling." :
            !source.Known ? "Source dimensions unavailable; RTX SR was not enabled." : scale > 8 ? "Required scale exceeds the VPP limit; using conventional scaling." :
            "Source already matches output, is downscaled, or requires aspect correction; RTX SR is unnecessary.");
        if (options.RtxHdr && !hdr) reasons.Add("RTX HDR requires known SDR video and an enabled HDR display on a compatible path.");
        if (bitstreamRequested) reasons.Add("Endpoint bitstream support is unverified; using PCM audio.");
        // A Windows path parses as an absolute URI with a drive-letter scheme, so match the scheme, not the shape.
        if (!streamHelperAvailable && items.Any(x => Uri.TryCreate(x, UriKind.Absolute, out var link) && link.Scheme is "http" or "https"))
            reasons.Add("yt-dlp was not found, so site pages cannot be resolved. Direct media links still play.");
        var args = ImmutableArray.CreateBuilder<string>();
        args.Add("--config-dir=" + configDir);
        args.Add("--profile=" + (options.Profile == "Automatic" ? "reference" : options.Profile.ToLowerInvariant()));
        string renderer = compatible ? "Compatibility D3D11" : rtxLane ? "RTX D3D11" : capabilities.Nvidia ? "NVIDIA Vulkan" : "Managed Vulkan";
        if (!compatible && !rtxLane && capabilities.Nvidia) args.Add("--profile=nvidia");
        args.Add("--profile=pcm-safe");
        args.Add("--vo=gpu-next");
        args.Add("--input-ipc-server=\\\\.\\pipe\\" + pipeName);
        args.Add("--terminal=no");
        args.Add("--screen=" + target.Screen);
        args.Add("--fs-screen=" + target.Screen);
        if (target.Fullscreen) args.Add("--fullscreen");
        else if (target.Width > 0 && target.Height > 0) args.Add($"--autofit={target.Width}x{target.Height}");
        if (rtxLane)
        {
            args.Add("--gpu-api=d3d11"); args.Add("--gpu-context=d3d11"); args.Add("--hwdec=d3d11va");
            if (!string.IsNullOrWhiteSpace(capabilities.NvidiaAdapter)) args.Add("--d3d11-adapter=" + capabilities.NvidiaAdapter);
            var filter = new List<string>();
            if (sr) { filter.Add("scale=" + scale.ToString("0.######", CultureInfo.InvariantCulture)); filter.Add("scaling-mode=nvidia"); }
            if (hdr) filter.Add("nvidia-true-hdr=yes");
            if (filter.Count > 0) args.Add("--vf=@adaptive-vpp:d3d11vpp=" + string.Join(":", filter));
        }
        // RTX SR replaces conventional upscaling. Without it, an explicit quality
        // request must still reach libplacebo, including on the RTX lane, or the
        // plan would claim high quality scaling it never configured.
        if (!sr && options.UpscaleMode != "Off")
        {
            args.Add("--scale=ewa_lanczossharp"); args.Add("--cscale=spline36");
            args.Add("--dscale=mitchell"); args.Add("--sigmoid-upscaling=yes");
        }
        args.Add("--script=" + Path.Combine(configDir, "runtime", "adaptive-playback.lua"));
        args.Add($"--script-opts=adaptive-playback-sr={(rtxLane && rtxRequested ? "yes" : "no")},adaptive-playback-hdr={(hdr ? "yes" : "no")}");
        string cleanup = options.CleanupMode == "Legacy" ? options.Cleanup ? "Normal" : "Off" : options.CleanupMode;
        if (cleanup == "Automatic")
        {
            // Only the first item is probed, so a playlist cannot be judged item by
            // item; never apply one item's inferred policy to the rest.
            bool playlist = items.Count > 1;
            cleanup = playlist || source.IsHdr || source.PixelFormat.Contains("p10") || source.PixelFormat.Contains("p12") || !source.Known ? "Off" : "Gentle";
            reasons.Add(playlist
                ? "Automatic banding reduction: Off. Later playlist items are not inspected before playback."
                : "Automatic banding reduction: " + cleanup + ". Grain and source quality cannot be inferred reliably.");
        }
        if (cleanup != "Off")
        {
            args.Add("--deband=yes"); args.Add("--deband-iterations=" + (cleanup == "Gentle" ? "1" : "2"));
            args.Add("--deband-threshold=" + (cleanup == "Gentle" ? "16" : cleanup == "Strong" ? "48" : "32"));
            args.Add("--deband-range=" + (cleanup == "Strong" ? "24" : "16")); args.Add("--deband-grain=24");
        }
        if (options.MotionMode != "Off")
        {
            args.AddRange(new string[] { "--video-sync=display-resample", "--video-sync-max-factor=10", "--interpolation=yes",
                "--tscale=" + (options.MotionMode == "Gentle" ? "oversample" : "linear") });
            if (!compatible && !rtxLane) args.Add("--vulkan-swap-mode=fifo");
        }
        if (!string.IsNullOrWhiteSpace(options.YtdlFormat)) { args.Add("--ytdl=yes"); args.Add("--ytdl-format=" + options.YtdlFormat); }
        args.Add("--"); args.AddRange(items);
        return new(executable, args.ToImmutable(), options, source, target, renderer, sr, hdr, scale, reasons.ToImmutable(), pipeName);
    }
}

