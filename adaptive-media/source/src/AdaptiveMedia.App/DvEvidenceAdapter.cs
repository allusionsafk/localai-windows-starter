using System.Collections.Immutable;
using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace AdaptiveMedia;

public sealed class DvEvidenceAdapter
{
    private static readonly TimeSpan ToolTimeout = TimeSpan.FromMinutes(5);
    private readonly DvToolPaths tools;
    private readonly IDvToolProcess process;

    public DvEvidenceAdapter(DvToolPaths tools, IDvToolProcess process)
    {
        this.tools = tools ?? throw new ArgumentNullException(nameof(tools));
        this.process = process ?? throw new ArgumentNullException(nameof(process));
    }

    public Task<DvMatroskaEvidence> ReadAsync(string sourcePath, CancellationToken cancellationToken) =>
        ReadAsync(sourcePath, cancellationToken, null);

    internal async Task<DvMatroskaEvidence> ReadAsync(string sourcePath, CancellationToken cancellationToken,
        Action<long>? scratchObserver)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sourcePath);
        sourcePath = Path.GetFullPath(sourcePath);
        if (!File.Exists(sourcePath)) throw new FileNotFoundException("Dolby Vision source was not found.", sourcePath);

        string work = Path.Combine(Path.GetTempPath(), "adaptive-media-dv-evidence-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(work);
        try
        {
            DvToolResult identify = await RequiredAsync(tools.MkvMerge, ["-J", sourcePath], work, cancellationToken);
            DvMatroskaInventory inventory = ParseInventory(identify.Output);
            DvTrackInventory[] videoTracks = inventory.Tracks.Where(track => track.Type == "video").ToArray();
            if (videoTracks.Length != 1) throw new DvEvidenceException("Exactly one Matroska video track is required.");
            DvTrackInventory videoTrack = videoTracks[0];
            if (!string.Equals(videoTrack.CodecId, "V_MPEGH/ISO/HEVC", StringComparison.Ordinal))
                throw new DvEvidenceException("The selected Matroska video track is not HEVC.");

            DvToolResult streamProbe = await RequiredAsync(tools.Ffprobe,
                ["-v", "error", "-count_packets", "-select_streams", "v:0", "-show_streams", "-of", "json", sourcePath],
                work, cancellationToken);
            DvToolResult frameProbe = await RequiredAsync(tools.Ffprobe,
                ["-v", "error", "-select_streams", "v:0", "-show_frames", "-read_intervals", "%+#1", "-of", "json", sourcePath],
                work, cancellationToken);
            ProbeFacts probe = ParseProbe(streamProbe.Output, frameProbe.Output);

            string elementary = Path.Combine(work, "source.hevc");
            await RequiredAsync(tools.MkvExtract, [sourcePath, "tracks", $"{videoTrack.Id}:{elementary}"], work, cancellationToken);
            ObserveScratch(work, scratchObserver);
            string rpu = Path.Combine(work, "source.rpu.bin");
            DvToolResult extraction = await process.RunAsync(tools.DoviTool,
                ["extract-rpu", "-i", elementary, "-o", rpu], work, ToolTimeout, cancellationToken);
            ObserveScratch(work, scratchObserver);
            if (extraction.ExitCode != 0 || !File.Exists(rpu) || new FileInfo(rpu).Length == 0)
            {
                DvDetection detection = probe.DvProfile is null ? DvDetection.NotDetected : DvDetection.Detected;
                DvRpuStatus rpuStatus = probe.DvProfile is null ? DvRpuStatus.Absent : DvRpuStatus.Malformed;
                var absent = new DvSourceInfo(detection, probe.DvProfile, probe.CompatibilityId,
                    probe.Media, probe.Hdr10Base, DvEnhancementLayer.Unknown, rpuStatus, probe.BitDepth,
                    "dovi_tool could not extract a complete RPU stream: " + Compact(extraction.Error));
                return new(sourcePath, absent, videoTrack.Id, videoTrack.Uid, 0, probe.PacketCount,
                    false, probe.StaticHdrMetadata, inventory, absent.Evidence ?? string.Empty);
            }

            DvToolResult info = await RequiredAsync(tools.DoviTool, ["info", "--summary", "-i", rpu], work, cancellationToken);
            DoviSummary summary = ParseDoviSummary(info.Output + Environment.NewLine + info.Error);
            string enhancement = Path.Combine(work, "source.el.hevc");
            DvToolResult demux = await process.RunAsync(tools.DoviTool,
                ["demux", "--el-only", elementary, "--el-out", enhancement], work, ToolTimeout, cancellationToken);
            ObserveScratch(work, scratchObserver);
            string demuxDiagnostic = Compact(demux.Error + Environment.NewLine + demux.Output);
            bool explicitNoEl = demux.ExitCode == 1 &&
                demuxDiagnostic == "Error: No enhancement layer was found in input file" && !File.Exists(enhancement);
            bool demuxSucceeded = demux.ExitCode == 0 || explicitNoEl;
            bool actualEl = demuxSucceeded && File.Exists(enhancement) && new FileInfo(enhancement).Length > 0;

            bool profileAgreement = probe.DvProfile == summary.Profile && probe.RpuPresent == true;
            bool countAgreement = summary.Frames > 0 && summary.Frames == probe.PacketCount;
            bool elAgreement = demuxSucceeded && probe.ElPresent == actualEl;
            DvRpuStatus status = profileAgreement && countAgreement && elAgreement
                ? DvRpuStatus.Validated : DvRpuStatus.Malformed;
            DvEnhancementLayer layer = summary.Profile switch
            {
                7 when demuxSucceeded && actualEl && summary.Subprofile == "MEL" => DvEnhancementLayer.Mel,
                7 when demuxSucceeded && actualEl && summary.Subprofile == "FEL" => DvEnhancementLayer.Fel,
                8 when demuxSucceeded && !actualEl => DvEnhancementLayer.None,
                _ => DvEnhancementLayer.Unknown
            };
            string evidence = $"mkvmerge JSON + ffprobe configuration/HDR + dovi_tool whole-stream parse: " +
                $"profile={summary.Profile}, subprofile={summary.Subprofile ?? "none"}, RPUs={summary.Frames}, " +
                $"packets={probe.PacketCount}, elProbeSucceeded={demuxSucceeded}, actualEL={actualEl}, " +
                $"HDR10static={probe.StaticHdrMetadata}.";
            var source = new DvSourceInfo(DvDetection.Detected, summary.Profile, probe.CompatibilityId,
                probe.Media, probe.Hdr10Base, layer, status, probe.BitDepth, evidence);
            return new(sourcePath, source, videoTrack.Id, videoTrack.Uid, summary.Frames,
                probe.PacketCount, actualEl, probe.StaticHdrMetadata, inventory, evidence);
        }
        finally
        {
            try { Directory.Delete(work, recursive: true); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    private async Task<DvToolResult> RequiredAsync(string executable, IReadOnlyList<string> arguments,
        string workingDirectory, CancellationToken cancellationToken)
    {
        DvToolResult result = await process.RunAsync(executable, arguments, workingDirectory, ToolTimeout, cancellationToken);
        if (result.ExitCode != 0)
            throw new DvEvidenceException($"Required tool '{Path.GetFileName(executable)}' failed: {Compact(result.Error)}");
        return result;
    }

    private static void ObserveScratch(string work, Action<long>? observer)
    {
        if (observer is null) return;
        long total = 0;
        foreach (string path in Directory.EnumerateFiles(work, "*", SearchOption.AllDirectories))
        {
            long length = new FileInfo(path).Length;
            total = total > long.MaxValue - length ? long.MaxValue : total + length;
        }
        observer(total);
    }

    private static string Compact(string value) => Regex.Replace(value ?? string.Empty, @"\s+", " ").Trim();

    private static DoviSummary ParseDoviSummary(string text)
    {
        Match frames = Regex.Match(text, @"(?m)^\s*Frames:\s*(\d+)\s*$", RegexOptions.CultureInvariant);
        Match profile = Regex.Match(text, @"(?m)^\s*Profile:\s*(\d+)(?:\s*\((MEL|FEL)\))?\s*$", RegexOptions.CultureInvariant);
        if (!frames.Success || !profile.Success)
            throw new DvEvidenceException("dovi_tool did not return a complete summary.");
        return new(int.Parse(frames.Groups[1].Value, CultureInfo.InvariantCulture),
            int.Parse(profile.Groups[1].Value, CultureInfo.InvariantCulture),
            profile.Groups[2].Success ? profile.Groups[2].Value : null);
    }

    private static ProbeFacts ParseProbe(string streamJson, string frameJson)
    {
        using JsonDocument streams = JsonDocument.Parse(streamJson);
        JsonElement streamArray = streams.RootElement.GetProperty("streams");
        if (streamArray.GetArrayLength() != 1) throw new DvEvidenceException("FFprobe did not return the selected video stream.");
        JsonElement stream = streamArray[0];
        string codec = Text(stream, "codec_name") ?? "unknown";
        int width = Integer(stream, "width") ?? 0;
        int height = Integer(stream, "height") ?? 0;
        string pixelFormat = Text(stream, "pix_fmt") ?? "unknown";
        string transfer = Text(stream, "color_transfer") ?? "unknown";
        string primaries = Text(stream, "color_primaries") ?? "unknown";
        string matrix = Text(stream, "color_space") ?? "unknown";
        int packets = ParseInteger(Text(stream, "nb_read_packets")) ?? 0;
        double fps = ParseRate(Text(stream, "avg_frame_rate") ?? Text(stream, "r_frame_rate"));
        int? bitDepth = pixelFormat.Contains("10", StringComparison.Ordinal) ? 10 : null;

        int? dvProfile = null;
        int? compatibilityId = null;
        bool? rpuPresent = null;
        bool? elPresent = null;
        if (stream.TryGetProperty("side_data_list", out JsonElement sideData))
        {
            foreach (JsonElement side in sideData.EnumerateArray())
            {
                if (Text(side, "side_data_type") != "DOVI configuration record") continue;
                dvProfile = Integer(side, "dv_profile");
                compatibilityId = Integer(side, "dv_bl_signal_compatibility_id");
                rpuPresent = Integer(side, "rpu_present_flag") == 1;
                elPresent = Integer(side, "el_present_flag") == 1;
            }
        }

        bool mastering = false;
        bool contentLight = false;
        using JsonDocument frames = JsonDocument.Parse(frameJson);
        if (frames.RootElement.TryGetProperty("frames", out JsonElement frameArray) && frameArray.GetArrayLength() > 0 &&
            frameArray[0].TryGetProperty("side_data_list", out JsonElement frameSideData))
        {
            foreach (JsonElement side in frameSideData.EnumerateArray())
            {
                string? type = Text(side, "side_data_type");
                mastering |= type == "Mastering display metadata";
                contentLight |= type == "Content light level metadata";
            }
        }

        bool staticHdr = mastering && contentLight;
        bool compatible = codec == "hevc" && bitDepth == 10 && pixelFormat.StartsWith("yuv420p10", StringComparison.Ordinal) &&
            transfer == "smpte2084" && primaries == "bt2020" && matrix == "bt2020nc" && staticHdr;
        bool incompatible = codec != "hevc" || (bitDepth is not null && bitDepth != 10) ||
            (transfer != "unknown" && transfer != "smpte2084") ||
            (primaries != "unknown" && primaries != "bt2020") ||
            (matrix != "unknown" && matrix != "bt2020nc");
        DvCompatibility hdr10 = compatible ? DvCompatibility.Yes : incompatible ? DvCompatibility.No : DvCompatibility.Unknown;
        var media = new MediaInfo(width, height, fps, codec,
            transfer == "smpte2084" ? "pq" : transfer,
            primaries == "bt2020" ? "bt.2020" : primaries,
            PixelFormat: pixelFormat);
        return new(media, packets, bitDepth, dvProfile, compatibilityId, rpuPresent, elPresent, staticHdr, hdr10);
    }

    private static DvMatroskaInventory ParseInventory(string json)
    {
        using JsonDocument document = JsonDocument.Parse(json);
        JsonElement root = document.RootElement;
        JsonElement container = root.GetProperty("container");
        if (!container.GetProperty("recognized").GetBoolean() || !container.GetProperty("supported").GetBoolean() ||
            Text(container, "type") != "Matroska")
            throw new DvEvidenceException("Source is not a supported Matroska container.");
        JsonElement containerProperties = container.GetProperty("properties");

        var tracks = ImmutableArray.CreateBuilder<DvTrackInventory>();
        foreach (JsonElement track in root.GetProperty("tracks").EnumerateArray())
        {
            JsonElement p = track.GetProperty("properties");
            tracks.Add(new(
                track.GetProperty("id").GetInt32(),
                Unsigned(p, "uid") ?? 0,
                Text(track, "type") ?? "unknown",
                Text(p, "codec_id") ?? "unknown",
                Text(p, "language"), Text(p, "language_ietf"), Text(p, "track_name"),
                Boolean(p, "default_track", false), Boolean(p, "forced_track", false),
                Boolean(p, "enabled_track", true), Boolean(p, "hearing_impaired", false),
                Boolean(p, "visual_impaired", false), Boolean(p, "original", false),
                Boolean(p, "commentary", false), Long(p, "default_duration"),
                Text(p, "pixel_dimensions"), Text(p, "display_dimensions"),
                Integer(p, "audio_channels"), Integer(p, "audio_bits_per_sample"),
                Double(p, "audio_sampling_frequency"), Boolean(p, "text_subtitles", false)));
        }

        var attachments = ImmutableArray.CreateBuilder<DvAttachmentInventory>();
        if (root.TryGetProperty("attachments", out JsonElement attachmentArray))
        {
            foreach (JsonElement attachment in attachmentArray.EnumerateArray())
            {
                JsonElement p = attachment.GetProperty("properties");
                attachments.Add(new(attachment.GetProperty("id").GetInt32(), Unsigned(p, "uid") ?? 0,
                    Text(attachment, "file_name") ?? string.Empty, Text(attachment, "content_type") ?? string.Empty,
                    Text(attachment, "description") ?? string.Empty, Long(attachment, "size") ?? 0));
            }
        }
        int chapters = root.TryGetProperty("chapters", out JsonElement chapterArray)
            ? chapterArray.EnumerateArray().Sum(item => Integer(item, "num_entries") ?? 0) : 0;
        int globalTags = root.TryGetProperty("global_tags", out JsonElement tagArray)
            ? tagArray.EnumerateArray().Sum(item => Integer(item, "num_entries") ?? 0) : 0;
        return new(tracks.ToImmutable(), attachments.ToImmutable(), chapters, globalTags,
            Text(containerProperties, "title"), Text(containerProperties, "date_utc"),
            Long(containerProperties, "duration"), Long(containerProperties, "timestamp_scale"));
    }

    private static string? Text(JsonElement element, string name) =>
        element.TryGetProperty(name, out JsonElement value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
    private static int? Integer(JsonElement element, string name) =>
        element.TryGetProperty(name, out JsonElement value) && value.TryGetInt32(out int number) ? number : null;
    private static long? Long(JsonElement element, string name) =>
        element.TryGetProperty(name, out JsonElement value) && value.TryGetInt64(out long number) ? number : null;
    private static ulong? Unsigned(JsonElement element, string name) =>
        element.TryGetProperty(name, out JsonElement value) && value.TryGetUInt64(out ulong number) ? number : null;
    private static double? Double(JsonElement element, string name) =>
        element.TryGetProperty(name, out JsonElement value) && value.TryGetDouble(out double number) ? number : null;
    private static bool Boolean(JsonElement element, string name, bool fallback) =>
        element.TryGetProperty(name, out JsonElement value) && value.ValueKind is JsonValueKind.True or JsonValueKind.False ? value.GetBoolean() : fallback;
    private static int? ParseInteger(string? value) => int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out int number) ? number : null;
    private static double ParseRate(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return 0;
        string[] parts = value.Split('/');
        if (parts.Length == 2 && double.TryParse(parts[0], NumberStyles.Float, CultureInfo.InvariantCulture, out double numerator) &&
            double.TryParse(parts[1], NumberStyles.Float, CultureInfo.InvariantCulture, out double denominator) && denominator != 0)
            return numerator / denominator;
        return double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out double rate) ? rate : 0;
    }

    private sealed record DoviSummary(int Frames, int Profile, string? Subprofile);
    private sealed record ProbeFacts(MediaInfo Media, int PacketCount, int? BitDepth,
        int? DvProfile, int? CompatibilityId, bool? RpuPresent, bool? ElPresent,
        bool StaticHdrMetadata, DvCompatibility Hdr10Base);
}
