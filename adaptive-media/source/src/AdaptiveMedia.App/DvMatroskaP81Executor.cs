using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml.Linq;

namespace AdaptiveMedia;

public sealed record DvExecutionRequest(string SourcePath, string DestinationPath,
    DvConversionPlan Plan, bool AcknowledgeFelLoss);

public sealed record DvValidationReport(
    bool Profile81,
    bool RpuValidated,
    bool EnhancementLayerAbsent,
    bool BaseVideoIdentical,
    bool VideoTimestampsIdentical,
    bool NonVideoPayloadsIdentical,
    bool TrackInventoryPreserved,
    bool ChaptersPreserved,
    bool AttachmentsPreserved,
    bool MetadataPreserved,
    string? FailureDetail = null);

public sealed record DvExecutionResult(
    bool Promoted,
    string SourceSha256Before,
    string SourceSha256After,
    string OutputSha256,
    string BaseVideoSha256,
    DvSourceInfo Source,
    DvSourceInfo Output,
    DvLossClassification Losses,
    ImmutableArray<DvReasonCode> Codes,
    DvValidationReport Validation);

public sealed class DvFelLossAcknowledgementRequiredException()
    : InvalidOperationException("Profile 7 FEL picture contribution will be discarded; explicit acknowledgement is required.");

public sealed class DvExecutionException(string message) : IOException(message);

public sealed class DvMatroskaP81Executor
{
    private static readonly TimeSpan ToolTimeout = TimeSpan.FromMinutes(30);
    private static readonly HashSet<string> GeneratedStatisticTags = new(StringComparer.Ordinal)
    {
        "BPS", "DURATION", "NUMBER_OF_FRAMES", "NUMBER_OF_BYTES",
        "_STATISTICS_WRITING_APP", "_STATISTICS_WRITING_DATE_UTC", "_STATISTICS_TAGS"
    };

    private readonly DvToolPaths tools;
    private readonly IDvToolProcess process;
    private readonly DvEvidenceAdapter evidence;

    public DvMatroskaP81Executor(DvToolPaths tools, IDvToolProcess process)
    {
        this.tools = tools ?? throw new ArgumentNullException(nameof(tools));
        this.process = process ?? throw new ArgumentNullException(nameof(process));
        evidence = new DvEvidenceAdapter(tools, process);
    }

    public async Task<DvExecutionResult> ExecuteAsync(DvExecutionRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(request.Plan);
        string source = Path.GetFullPath(request.SourcePath);
        string destination = Path.GetFullPath(request.DestinationPath);
        if (!File.Exists(source)) throw new FileNotFoundException("Dolby Vision source was not found.", source);
        if (PathsEqual(source, destination)) throw new IOException("Source and destination must be different files.");
        if (File.Exists(destination)) throw new IOException("The destination already exists and will not be overwritten.");
        ValidateExecutablePlan(request.Plan);
        if (request.Plan.Source.EnhancementLayer == DvEnhancementLayer.Fel && !request.AcknowledgeFelLoss)
            throw new DvFelLossAcknowledgementRequiredException();

        string? destinationDirectory = Path.GetDirectoryName(destination);
        if (string.IsNullOrEmpty(destinationDirectory) || !Directory.Exists(destinationDirectory))
            throw new DirectoryNotFoundException($"Destination directory does not exist: {destinationDirectory}");

        string sourceHashBefore = await HashFileAsync(source, cancellationToken).ConfigureAwait(false);
        string transaction = Path.Combine(destinationDirectory, ".adaptivemedia-dv-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(transaction);
        string temporaryOutput = Path.Combine(transaction, "validated-output.mkv");
        try
        {
            DvMatroskaEvidence sourceEvidence = await evidence.ReadAsync(source, cancellationToken).ConfigureAwait(false);
            DvConversionPlan observedPlan = DvConversionPlanner.Build(sourceEvidence.Source, DvConversionTarget.Profile81);
            if (!EquivalentPlans(request.Plan, observedPlan))
                throw new DvExecutionException("The supplied plan no longer matches evidence read from the source.");

            ExtractedMedia sourceMedia = await ExtractAsync(source, sourceEvidence.Inventory, "source", transaction, cancellationToken)
                .ConfigureAwait(false);
            string convertedVideo = Path.Combine(transaction, "converted-video.hevc");
            await RequiredAsync(tools.DoviTool,
                ["-m", "2", "convert", "--discard", sourceMedia.VideoPayload, "-o", convertedVideo],
                transaction, cancellationToken).ConfigureAwait(false);
            if (!File.Exists(convertedVideo) || new FileInfo(convertedVideo).Length == 0)
                throw new DvExecutionException("dovi_tool did not produce a converted HEVC stream.");

            await RemuxAsync(source, temporaryOutput, convertedVideo, sourceEvidence.Inventory,
                sourceMedia.VideoTimestamps, transaction, cancellationToken).ConfigureAwait(false);
            if (!File.Exists(temporaryOutput) || new FileInfo(temporaryOutput).Length == 0)
                throw new DvExecutionException("mkvmerge did not produce a temporary Matroska output.");

            ulong outputVideoUid = await ReadVideoTrackUidAsync(temporaryOutput, transaction, cancellationToken).ConfigureAwait(false);
            DvTrackInventory sourceVideo = sourceEvidence.Inventory.Tracks.Single(track => track.Id == sourceEvidence.VideoTrackId);
            if (sourceVideo.DefaultDuration is long defaultDuration)
            {
                await RequiredAsync(tools.MkvPropEdit,
                    [temporaryOutput, "--edit", "track:v1", "--set", $"default-duration={defaultDuration}"],
                    transaction, cancellationToken).ConfigureAwait(false);
            }
            string rewrittenTags = Path.Combine(transaction, "preserved-tags.xml");
            RewriteTags(sourceMedia.Tags, rewrittenTags, sourceEvidence.VideoTrackUid, outputVideoUid);
            await RequiredAsync(tools.MkvPropEdit,
                [temporaryOutput, "--tags", $"all:{rewrittenTags}"], transaction, cancellationToken).ConfigureAwait(false);

            DvMatroskaEvidence outputEvidence = await evidence.ReadAsync(temporaryOutput, cancellationToken).ConfigureAwait(false);
            ExtractedMedia outputMedia = await ExtractAsync(temporaryOutput, outputEvidence.Inventory, "output", transaction, cancellationToken)
                .ConfigureAwait(false);
            DvValidationReport validation = await ValidateAsync(sourceEvidence, outputEvidence, sourceMedia, outputMedia,
                transaction, cancellationToken).ConfigureAwait(false);
            RequireAllValidation(validation);

            string sourceHashAfter = await HashFileAsync(source, cancellationToken).ConfigureAwait(false);
            if (!string.Equals(sourceHashBefore, sourceHashAfter, StringComparison.Ordinal))
                throw new DvExecutionException("The source changed during conversion; the output will not be promoted.");
            string outputHash = await HashFileAsync(temporaryOutput, cancellationToken).ConfigureAwait(false);
            string baseHash = await NormalizedBaseHashAsync(sourceMedia.VideoPayload, "result-base", transaction, cancellationToken)
                .ConfigureAwait(false);

            File.Move(temporaryOutput, destination, overwrite: false);
            return new(true, sourceHashBefore, sourceHashAfter, outputHash, baseHash,
                sourceEvidence.Source, outputEvidence.Source, observedPlan.Losses, observedPlan.Codes, validation);
        }
        finally
        {
            try { Directory.Delete(transaction, recursive: true); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    private async Task<ExtractedMedia> ExtractAsync(string matroska, DvMatroskaInventory inventory,
        string prefix, string work, CancellationToken cancellationToken)
    {
        var payloads = new Dictionary<int, string>();
        var timestamps = new Dictionary<int, string>();
        foreach (DvTrackInventory track in inventory.Tracks)
        {
            string extension = track.Type == "video" ? ".hevc" : ".bin";
            string payload = Path.Combine(work, $"{prefix}-track-{track.Id}{extension}");
            string timestamp = Path.Combine(work, $"{prefix}-timestamps-{track.Id}.txt");
            await RequiredAsync(tools.MkvExtract, [matroska, "tracks", $"{track.Id}:{payload}"], work, cancellationToken)
                .ConfigureAwait(false);
            await RequiredAsync(tools.MkvExtract, [matroska, "timestamps_v2", $"{track.Id}:{timestamp}"], work, cancellationToken)
                .ConfigureAwait(false);
            payloads.Add(track.Id, payload);
            timestamps.Add(track.Id, timestamp);
        }

        string chapters = Path.Combine(work, $"{prefix}-chapters.xml");
        if (inventory.ChapterEntries > 0)
            await RequiredAsync(tools.MkvExtract, [matroska, "chapters", chapters], work, cancellationToken).ConfigureAwait(false);
        string tags = Path.Combine(work, $"{prefix}-tags.xml");
        await RequiredAsync(tools.MkvExtract, [matroska, "tags", tags], work, cancellationToken).ConfigureAwait(false);

        var attachments = new Dictionary<int, string>();
        foreach (DvAttachmentInventory attachment in inventory.Attachments)
        {
            string path = Path.Combine(work, $"{prefix}-attachment-{attachment.Id}.bin");
            await RequiredAsync(tools.MkvExtract, [matroska, "attachments", $"{attachment.Id}:{path}"], work, cancellationToken)
                .ConfigureAwait(false);
            attachments.Add(attachment.Id, path);
        }

        int videoId = inventory.Tracks.Single(track => track.Type == "video").Id;
        return new(payloads[videoId], timestamps[videoId], payloads, timestamps, attachments, chapters, tags);
    }

    private async Task RemuxAsync(string source, string output, string convertedVideo,
        DvMatroskaInventory inventory, string videoTimestamps, string work, CancellationToken cancellationToken)
    {
        DvTrackInventory video = inventory.Tracks.Single(track => track.Type == "video");
        var arguments = new List<string> { "-o", output };
        if (inventory.Title is not null) arguments.AddRange(["--title", inventory.Title]);
        if (inventory.DateUtc is not null) arguments.AddRange(["--date", inventory.DateUtc]);
        arguments.AddRange(["--no-video", "--no-track-tags", "--no-global-tags", source]);
        arguments.AddRange(["--timestamps", $"0:{videoTimestamps}"]);
        AddTrackHeaderArguments(arguments, video);
        arguments.Add(convertedVideo);

        var order = new List<string>();
        foreach (DvTrackInventory track in inventory.Tracks)
            order.Add(track.Id == video.Id ? "1:0" : $"0:{track.Id}");
        arguments.AddRange(["--track-order", string.Join(',', order)]);
        await RequiredAsync(tools.MkvMerge, arguments, work, cancellationToken).ConfigureAwait(false);
    }

    private static void AddTrackHeaderArguments(List<string> arguments, DvTrackInventory track)
    {
        if (track.LanguageIetf is not null) arguments.AddRange(["--language", $"0:{track.LanguageIetf}"]);
        else if (track.Language is not null) arguments.AddRange(["--language", $"0:{track.Language}"]);
        if (track.Name is not null) arguments.AddRange(["--track-name", $"0:{track.Name}"]);
        AddFlag(arguments, "--default-track-flag", track.Default);
        AddFlag(arguments, "--forced-display-flag", track.Forced);
        AddFlag(arguments, "--track-enabled-flag", track.Enabled);
        AddFlag(arguments, "--hearing-impaired-flag", track.HearingImpaired);
        AddFlag(arguments, "--visual-impaired-flag", track.VisualImpaired);
        AddFlag(arguments, "--original-flag", track.Original);
        AddFlag(arguments, "--commentary-flag", track.Commentary);
    }

    private static void AddFlag(List<string> arguments, string name, bool enabled) =>
        arguments.AddRange([name, $"0:{(enabled ? "yes" : "no")}"]);

    private async Task<DvValidationReport> ValidateAsync(DvMatroskaEvidence sourceEvidence,
        DvMatroskaEvidence outputEvidence, ExtractedMedia source, ExtractedMedia output,
        string work, CancellationToken cancellationToken)
    {
        bool profile = outputEvidence.Source is { Detection: DvDetection.Detected, Profile: 8, CompatibilityId: 1,
            Hdr10Base: DvCompatibility.Yes };
        bool rpu = outputEvidence.Source.Rpu == DvRpuStatus.Validated &&
            outputEvidence.RpuFrameCount == outputEvidence.VideoPacketCount && outputEvidence.RpuFrameCount > 0;
        bool noEnhancement = outputEvidence.Source.EnhancementLayer == DvEnhancementLayer.None &&
            !outputEvidence.EnhancementLayerPresent;

        string sourceBase = await NormalizedBaseHashAsync(source.VideoPayload, "source-base", work, cancellationToken)
            .ConfigureAwait(false);
        string outputBase = await NormalizedBaseHashAsync(output.VideoPayload, "output-base", work, cancellationToken)
            .ConfigureAwait(false);
        bool videoTimestamps = await FilesEqualAsync(source.VideoTimestamps, output.VideoTimestamps, cancellationToken)
            .ConfigureAwait(false);

        int sourceVideoId = sourceEvidence.VideoTrackId;
        int outputVideoId = outputEvidence.VideoTrackId;
        DvTrackInventory[] sourceNonVideo = sourceEvidence.Inventory.Tracks.Where(track => track.Id != sourceVideoId).ToArray();
        DvTrackInventory[] outputNonVideo = outputEvidence.Inventory.Tracks.Where(track => track.Id != outputVideoId).ToArray();
        bool nonVideoPayloads = sourceNonVideo.Length == outputNonVideo.Length;
        for (int index = 0; nonVideoPayloads && index < sourceNonVideo.Length; index++)
        {
            DvTrackInventory left = sourceNonVideo[index];
            DvTrackInventory right = outputNonVideo[index];
            nonVideoPayloads = left.Id == right.Id &&
                await FilesEqualAsync(source.Payloads[left.Id], output.Payloads[right.Id], cancellationToken).ConfigureAwait(false) &&
                await FilesEqualAsync(source.Timestamps[left.Id], output.Timestamps[right.Id], cancellationToken).ConfigureAwait(false);
        }

        bool tracks = InventoriesEqual(sourceEvidence.Inventory, outputEvidence.Inventory, sourceVideoId, outputVideoId);
        bool chapters = sourceEvidence.Inventory.ChapterEntries == outputEvidence.Inventory.ChapterEntries &&
            (sourceEvidence.Inventory.ChapterEntries == 0 || XmlEqual(source.Chapters, output.Chapters, null, null));
        bool attachmentInventory = sourceEvidence.Inventory.Attachments.SequenceEqual(outputEvidence.Inventory.Attachments);
        bool attachmentPayloads = attachmentInventory;
        foreach (DvAttachmentInventory item in sourceEvidence.Inventory.Attachments)
        {
            if (!attachmentPayloads || !output.Attachments.TryGetValue(item.Id, out string? outputPath))
            {
                attachmentPayloads = false;
                break;
            }
            attachmentPayloads = await FilesEqualAsync(source.Attachments[item.Id], outputPath, cancellationToken).ConfigureAwait(false);
        }
        bool title = sourceEvidence.Inventory.Title == outputEvidence.Inventory.Title;
        bool date = DatesEqual(sourceEvidence.Inventory.DateUtc, outputEvidence.Inventory.DateUtc);
        bool scale = sourceEvidence.Inventory.TimestampScale == outputEvidence.Inventory.TimestampScale;
        bool tags = XmlEqual(source.Tags, output.Tags, sourceEvidence.VideoTrackUid, outputEvidence.VideoTrackUid);
        bool metadata = title && date && scale && tags;
        string? detail = metadata ? null : $"metadata(title={title}, date={date}, timestampScale={scale}, tags={tags}; " +
            $"sourceTitle={sourceEvidence.Inventory.Title}, outputTitle={outputEvidence.Inventory.Title}; " +
            $"sourceDate={sourceEvidence.Inventory.DateUtc}, outputDate={outputEvidence.Inventory.DateUtc}; " +
            $"sourceScale={sourceEvidence.Inventory.TimestampScale}, outputScale={outputEvidence.Inventory.TimestampScale}; " +
            $"sourceTags={CanonicalTagXml(source.Tags, sourceEvidence.VideoTrackUid)}, " +
            $"outputTags={CanonicalTagXml(output.Tags, outputEvidence.VideoTrackUid)})";

        return new(profile, rpu, noEnhancement,
            string.Equals(sourceBase, outputBase, StringComparison.Ordinal), videoTimestamps,
            nonVideoPayloads, tracks, chapters, attachmentInventory && attachmentPayloads, metadata, detail);
    }

    private async Task<string> NormalizedBaseHashAsync(string video, string name, string work,
        CancellationToken cancellationToken)
    {
        string output = Path.Combine(work, name + ".hevc");
        await RequiredAsync(tools.DoviTool, ["remove", video, "-o", output], work, cancellationToken).ConfigureAwait(false);
        if (!File.Exists(output) || new FileInfo(output).Length == 0)
            throw new DvExecutionException("dovi_tool did not produce a normalized base stream for validation.");
        return await HashFileAsync(output, cancellationToken).ConfigureAwait(false);
    }

    private async Task<ulong> ReadVideoTrackUidAsync(string matroska, string work, CancellationToken cancellationToken)
    {
        DvToolResult result = await RequiredAsync(tools.MkvMerge, ["-J", matroska], work, cancellationToken).ConfigureAwait(false);
        using System.Text.Json.JsonDocument document = System.Text.Json.JsonDocument.Parse(result.Output);
        var videos = document.RootElement.GetProperty("tracks").EnumerateArray()
            .Where(track => track.GetProperty("type").GetString() == "video").ToArray();
        if (videos.Length != 1 || !videos[0].GetProperty("properties").GetProperty("uid").TryGetUInt64(out ulong uid))
            throw new DvExecutionException("Temporary output does not contain exactly one identified video track.");
        return uid;
    }

    private static void RewriteTags(string source, string destination, ulong sourceVideoUid, ulong outputVideoUid)
    {
        XDocument document = XDocument.Load(source);
        RemoveGeneratedStatistics(document);
        foreach (XElement uid in document.Descendants().Where(element => element.Name.LocalName == "TrackUID" &&
                     element.Value == sourceVideoUid.ToString(System.Globalization.CultureInfo.InvariantCulture)))
            uid.Value = outputVideoUid.ToString(System.Globalization.CultureInfo.InvariantCulture);
        document.Save(destination, SaveOptions.DisableFormatting);
    }

    private static bool XmlEqual(string left, string right, ulong? leftVideoUid, ulong? rightVideoUid)
    {
        XDocument first = XDocument.Load(left);
        XDocument second = XDocument.Load(right);
        RemoveGeneratedStatistics(first);
        RemoveGeneratedStatistics(second);
        NormalizeTagDefaults(first);
        NormalizeTagDefaults(second);
        NormalizeVideoUid(first, leftVideoUid);
        NormalizeVideoUid(second, rightVideoUid);
        return string.Equals(CanonicalElement(first.Root), CanonicalElement(second.Root), StringComparison.Ordinal);
    }

    private static string CanonicalTagXml(string path, ulong? videoUid)
    {
        XDocument document = XDocument.Load(path);
        RemoveGeneratedStatistics(document);
        NormalizeTagDefaults(document);
        NormalizeVideoUid(document, videoUid);
        return CanonicalElement(document.Root);
    }

    private static void NormalizeTagDefaults(XDocument document)
    {
        foreach (XElement simple in document.Descendants().Where(element => element.Name.LocalName == "Simple"))
        {
            bool hasLanguage = simple.Elements().Any(element =>
                element.Name.LocalName is "TagLanguage" or "TagLanguageIETF");
            if (!hasLanguage) simple.Add(new XElement(simple.Name.Namespace + "TagLanguageIETF", "und"));
        }
    }

    private static string CanonicalElement(XElement? element)
    {
        if (element is null) return string.Empty;
        var children = element.Elements().Select(CanonicalElement).OrderBy(value => value, StringComparer.Ordinal);
        var attributes = element.Attributes().Where(attribute => !attribute.IsNamespaceDeclaration)
            .Select(attribute => attribute.Name.LocalName + "=" + attribute.Value)
            .OrderBy(value => value, StringComparer.Ordinal);
        string directText = string.Concat(element.Nodes().OfType<XText>().Select(node => node.Value)).Trim();
        return new StringBuilder().Append('<').Append(element.Name.LocalName).Append('|')
            .AppendJoin(';', attributes).Append('|').Append(directText).Append('|')
            .AppendJoin(string.Empty, children).Append('>').ToString();
    }

    private static void RemoveGeneratedStatistics(XDocument document)
    {
        foreach (XElement simple in document.Descendants().Where(element => element.Name.LocalName == "Simple").ToArray())
        {
            string? name = simple.Elements().FirstOrDefault(element => element.Name.LocalName == "Name")?.Value;
            if (name is not null && GeneratedStatisticTags.Contains(name)) simple.Remove();
        }
        foreach (XElement tag in document.Descendants().Where(element => element.Name.LocalName == "Tag").ToArray())
        {
            if (!tag.Elements().Any(element => element.Name.LocalName == "Simple")) tag.Remove();
        }
    }

    private static void NormalizeVideoUid(XDocument document, ulong? uid)
    {
        if (uid is null) return;
        string value = uid.Value.ToString(System.Globalization.CultureInfo.InvariantCulture);
        foreach (XElement element in document.Descendants().Where(element => element.Name.LocalName == "TrackUID" && element.Value == value))
            element.Value = "0";
    }

    private static bool InventoriesEqual(DvMatroskaInventory source, DvMatroskaInventory output,
        int sourceVideoId, int outputVideoId)
    {
        if (source.Tracks.Length != output.Tracks.Length || source.DurationNanoseconds != output.DurationNanoseconds)
            return false;
        for (int index = 0; index < source.Tracks.Length; index++)
        {
            DvTrackInventory left = source.Tracks[index];
            DvTrackInventory right = output.Tracks[index];
            if (left.Id == sourceVideoId && right.Id == outputVideoId)
            {
                left = left with { Uid = 0 };
                right = right with { Uid = 0 };
            }
            if (left != right) return false;
        }
        return true;
    }

    private static bool DatesEqual(string? left, string? right)
    {
        if (left == right) return true;
        return DateTimeOffset.TryParse(left, out DateTimeOffset first) &&
            DateTimeOffset.TryParse(right, out DateTimeOffset second) && first == second;
    }

    private static async Task<bool> FilesEqualAsync(string left, string right, CancellationToken cancellationToken) =>
        new FileInfo(left).Length == new FileInfo(right).Length &&
        string.Equals(await HashFileAsync(left, cancellationToken).ConfigureAwait(false),
            await HashFileAsync(right, cancellationToken).ConfigureAwait(false), StringComparison.Ordinal);

    private static async Task<string> HashFileAsync(string path, CancellationToken cancellationToken)
    {
        await using FileStream stream = new(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1024 * 1024,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        byte[] hash = await SHA256.HashDataAsync(stream, cancellationToken).ConfigureAwait(false);
        return Convert.ToHexString(hash);
    }

    private async Task<DvToolResult> RequiredAsync(string executable, IReadOnlyList<string> arguments,
        string work, CancellationToken cancellationToken)
    {
        DvToolResult result = await process.RunAsync(executable, arguments, work, ToolTimeout, cancellationToken)
            .ConfigureAwait(false);
        if (result.ExitCode != 0)
            throw new DvExecutionException($"Required tool '{Path.GetFileName(executable)}' failed: " +
                Compact(result.Error + Environment.NewLine + result.Output));
        return result;
    }

    private static string Compact(string value) => Regex.Replace(value ?? string.Empty, @"\s+", " ").Trim();

    private static void ValidateExecutablePlan(DvConversionPlan plan)
    {
        if (!plan.Supported || !plan.Executable || plan.Target != DvConversionTarget.Profile81 ||
            plan.Source.Profile != 7 || plan.Method != DvConversionMethod.StreamCopyEnhancementLayerDiscard ||
            plan.RpuAction != DvRpuAction.RewriteToProfile81 || plan.EnhancementLayerAction != DvEnhancementLayerAction.Discard)
            throw new DvExecutionException("Only an executable Profile 7 to Profile 8.1 stream-copy plan is accepted.");
        if (plan.Source.EnhancementLayer == DvEnhancementLayer.Fel &&
            (!plan.Losses.HasFlag(DvLossClassification.FelPictureContributionLost) ||
             !plan.Codes.Contains(DvReasonCode.P7FelToP81FelDiscarded) ||
             !plan.Codes.Contains(DvReasonCode.FelPictureContributionNotRetained)))
            throw new DvExecutionException("The FEL plan does not expose all required loss diagnostics.");
    }

    private static bool EquivalentPlans(DvConversionPlan expected, DvConversionPlan actual) =>
        expected.Source == actual.Source && expected.Target == actual.Target && expected.Supported == actual.Supported &&
        expected.Executable == actual.Executable && expected.Method == actual.Method &&
        expected.RpuAction == actual.RpuAction && expected.EnhancementLayerAction == actual.EnhancementLayerAction &&
        expected.Losses == actual.Losses && expected.Codes.SequenceEqual(actual.Codes) && expected.ExpectedOutput == actual.ExpectedOutput;

    private static bool PathsEqual(string left, string right) =>
        string.Equals(left, right, OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);

    private static void RequireAllValidation(DvValidationReport validation)
    {
        if (validation.Profile81 && validation.RpuValidated && validation.EnhancementLayerAbsent &&
            validation.BaseVideoIdentical && validation.VideoTimestampsIdentical &&
            validation.NonVideoPayloadsIdentical && validation.TrackInventoryPreserved &&
            validation.ChaptersPreserved && validation.AttachmentsPreserved && validation.MetadataPreserved) return;
        throw new DvExecutionException("Independent output validation failed; the temporary file will not be promoted. " + validation);
    }

    private sealed record ExtractedMedia(string VideoPayload, string VideoTimestamps,
        IReadOnlyDictionary<int, string> Payloads, IReadOnlyDictionary<int, string> Timestamps,
        IReadOnlyDictionary<int, string> Attachments, string Chapters, string Tags);
}
