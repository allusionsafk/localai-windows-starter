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
    string DestinationPath,
    string SourceSha256Before,
    string SourceSha256After,
    string OutputSha256,
    string BaseVideoSha256,
    DvSourceInfo Source,
    DvSourceInfo Output,
    DvLossClassification Losses,
    ImmutableArray<DvReasonCode> Codes,
    DvValidationReport Validation,
    DvScratchPreflight ScratchPreflight,
    long PeakScratchBytes);

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
    private readonly IDvFreeSpaceProvider freeSpace;

    public DvMatroskaP81Executor(DvToolPaths tools, IDvToolProcess process,
        IDvFreeSpaceProvider? freeSpace = null)
    {
        this.tools = tools ?? throw new ArgumentNullException(nameof(tools));
        this.process = process ?? throw new ArgumentNullException(nameof(process));
        this.freeSpace = freeSpace ?? new DvDriveFreeSpaceProvider();
        evidence = new DvEvidenceAdapter(tools, process);
    }

    public DvScratchPreflight Preflight(string sourcePath, string destinationPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sourcePath);
        ArgumentException.ThrowIfNullOrWhiteSpace(destinationPath);
        string source = Path.GetFullPath(sourcePath);
        string destination = Path.GetFullPath(destinationPath);
        if (!File.Exists(source)) throw new FileNotFoundException("Dolby Vision source was not found.", source);
        string? destinationDirectory = Path.GetDirectoryName(destination);
        if (string.IsNullOrEmpty(destinationDirectory) || !Directory.Exists(destinationDirectory))
            throw new DirectoryNotFoundException($"Destination directory does not exist: {destinationDirectory}");
        return DvScratchPreflight.Calculate(new FileInfo(source).Length,
            freeSpace.GetAvailableBytes(destinationDirectory));
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

        DvScratchPreflight preflight = Preflight(source, destination);
        if (!preflight.Pass) throw new DvScratchSpaceException(preflight);

        string sourceHashBefore = await HashFileAsync(source, cancellationToken).ConfigureAwait(false);
        string transaction = Path.Combine(destinationDirectory, ".adaptivemedia-dv-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(transaction);
        var scratch = new ScratchTracker(transaction);
        string temporaryOutput = Path.Combine(transaction, "validated-output.mkv");
        try
        {
            DvMatroskaEvidence sourceEvidence = await evidence.ReadAsync(source, cancellationToken, scratch.ObserveExternal)
                .ConfigureAwait(false);
            DvConversionPlan observedPlan = DvConversionPlanner.Build(sourceEvidence.Source, DvConversionTarget.Profile81);
            if (!EquivalentPlans(request.Plan, observedPlan))
                throw new DvExecutionException("The supplied plan no longer matches evidence read from the source.");

            string sourceVideo = Path.Combine(transaction, $"source-track-{sourceEvidence.VideoTrackId}.hevc");
            await ExtractTrackAsync(source, sourceEvidence.VideoTrackId, sourceVideo, transaction, cancellationToken)
                .ConfigureAwait(false);
            string sourceVideoTimestamps = Path.Combine(transaction, $"source-timestamps-{sourceEvidence.VideoTrackId}.txt");
            await ExtractTimestampsAsync(source, sourceEvidence.VideoTrackId, sourceVideoTimestamps, transaction, cancellationToken)
                .ConfigureAwait(false);
            string sourceTags = Path.Combine(transaction, "source-tags.xml");
            await ExtractTagsAsync(source, sourceTags, transaction, cancellationToken).ConfigureAwait(false);
            scratch.Observe();

            string baseHash = await NormalizedBaseHashAsync(sourceVideo, "source-base", transaction, scratch, cancellationToken)
                .ConfigureAwait(false);
            string convertedVideo = Path.Combine(transaction, "converted-video.hevc");
            await RequiredAsync(tools.DoviTool,
                ["-m", "2", "convert", "--discard", sourceVideo, "-o", convertedVideo],
                transaction, cancellationToken).ConfigureAwait(false);
            if (!File.Exists(convertedVideo) || new FileInfo(convertedVideo).Length == 0)
                throw new DvExecutionException("dovi_tool did not produce a converted HEVC stream.");
            scratch.Observe();
            DeleteFile(sourceVideo);

            await RemuxAsync(source, temporaryOutput, convertedVideo, sourceEvidence.Inventory,
                sourceVideoTimestamps, transaction, cancellationToken).ConfigureAwait(false);
            if (!File.Exists(temporaryOutput) || new FileInfo(temporaryOutput).Length == 0)
                throw new DvExecutionException("mkvmerge did not produce a temporary Matroska output.");
            scratch.Observe();

            ulong outputVideoUid = await ReadVideoTrackUidAsync(temporaryOutput, transaction, cancellationToken).ConfigureAwait(false);
            DvTrackInventory sourceVideoTrack = sourceEvidence.Inventory.Tracks.Single(track => track.Id == sourceEvidence.VideoTrackId);
            if (sourceVideoTrack.DefaultDuration is long defaultDuration)
            {
                await RequiredAsync(tools.MkvPropEdit,
                    [temporaryOutput, "--edit", "track:v1", "--set", $"default-duration={defaultDuration}"],
                    transaction, cancellationToken).ConfigureAwait(false);
            }
            string rewrittenTags = Path.Combine(transaction, "preserved-tags.xml");
            RewriteTags(sourceTags, rewrittenTags, sourceEvidence.VideoTrackUid, outputVideoUid);
            await RequiredAsync(tools.MkvPropEdit,
                [temporaryOutput, "--tags", $"all:{rewrittenTags}"], transaction, cancellationToken).ConfigureAwait(false);
            scratch.Observe();
            DeleteFile(rewrittenTags);
            DeleteFile(convertedVideo);

            DvMatroskaEvidence outputEvidence = await evidence.ReadAsync(temporaryOutput, cancellationToken, scratch.ObserveExternal)
                .ConfigureAwait(false);
            DvValidationReport validation = await ValidateAsync(sourceEvidence, outputEvidence, source, temporaryOutput,
                sourceVideoTimestamps, sourceTags, baseHash, transaction, scratch, cancellationToken).ConfigureAwait(false);
            RequireAllValidation(validation);

            string outputHash = await HashFileAsync(temporaryOutput, cancellationToken).ConfigureAwait(false);
            scratch.Observe();
            string sourceHashAfter = await HashFileAsync(source, cancellationToken).ConfigureAwait(false);
            if (!string.Equals(sourceHashBefore, sourceHashAfter, StringComparison.Ordinal))
                throw new DvExecutionException("The source changed during conversion; the output will not be promoted.");

            cancellationToken.ThrowIfCancellationRequested();
            File.Move(temporaryOutput, destination, overwrite: false);
            return new(true, destination, sourceHashBefore, sourceHashAfter, outputHash, baseHash,
                sourceEvidence.Source, outputEvidence.Source, observedPlan.Losses, observedPlan.Codes, validation,
                preflight, scratch.PeakBytes);
        }
        finally
        {
            try { Directory.Delete(transaction, recursive: true); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    private Task ExtractTrackAsync(string matroska, int trackId, string output, string work,
        CancellationToken cancellationToken) =>
        RequiredAsync(tools.MkvExtract, [matroska, "tracks", $"{trackId}:{output}"], work, cancellationToken);

    private Task ExtractTimestampsAsync(string matroska, int trackId, string output, string work,
        CancellationToken cancellationToken) =>
        RequiredAsync(tools.MkvExtract, [matroska, "timestamps_v2", $"{trackId}:{output}"], work, cancellationToken);

    private Task ExtractTagsAsync(string matroska, string output, string work,
        CancellationToken cancellationToken) =>
        RequiredAsync(tools.MkvExtract, [matroska, "tags", output], work, cancellationToken);

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
        DvMatroskaEvidence outputEvidence, string sourceMatroska, string outputMatroska,
        string sourceVideoTimestamps, string sourceTags, string sourceBaseHash,
        string work, ScratchTracker scratch, CancellationToken cancellationToken)
    {
        bool profile = outputEvidence.Source is { Detection: DvDetection.Detected, Profile: 8, CompatibilityId: 1,
            Hdr10Base: DvCompatibility.Yes };
        bool rpu = outputEvidence.Source.Rpu == DvRpuStatus.Validated &&
            outputEvidence.RpuFrameCount == outputEvidence.VideoPacketCount && outputEvidence.RpuFrameCount > 0;
        bool noEnhancement = outputEvidence.Source.EnhancementLayer == DvEnhancementLayer.None &&
            !outputEvidence.EnhancementLayerPresent;

        int sourceVideoId = sourceEvidence.VideoTrackId;
        int outputVideoId = outputEvidence.VideoTrackId;
        string outputVideo = Path.Combine(work, $"output-track-{outputVideoId}.hevc");
        await ExtractTrackAsync(outputMatroska, outputVideoId, outputVideo, work, cancellationToken).ConfigureAwait(false);
        scratch.Observe();
        string outputBaseHash = await NormalizedBaseHashAsync(outputVideo, "output-base", work, scratch, cancellationToken)
            .ConfigureAwait(false);
        bool baseVideo = string.Equals(sourceBaseHash, outputBaseHash, StringComparison.Ordinal);
        DeleteFile(outputVideo);

        string outputVideoTimestamps = Path.Combine(work, $"output-timestamps-{outputVideoId}.txt");
        await ExtractTimestampsAsync(outputMatroska, outputVideoId, outputVideoTimestamps, work, cancellationToken)
            .ConfigureAwait(false);
        scratch.Observe();
        bool videoTimestamps = await FilesEqualAsync(sourceVideoTimestamps, outputVideoTimestamps, cancellationToken)
            .ConfigureAwait(false);
        DeleteFile(sourceVideoTimestamps);
        DeleteFile(outputVideoTimestamps);

        DvTrackInventory[] sourceNonVideo = sourceEvidence.Inventory.Tracks.Where(track => track.Id != sourceVideoId).ToArray();
        DvTrackInventory[] outputNonVideo = outputEvidence.Inventory.Tracks.Where(track => track.Id != outputVideoId).ToArray();
        bool nonVideoPayloads = sourceNonVideo.Length == outputNonVideo.Length;
        for (int index = 0; nonVideoPayloads && index < sourceNonVideo.Length; index++)
        {
            DvTrackInventory left = sourceNonVideo[index];
            DvTrackInventory right = outputNonVideo[index];
            if (left.Id != right.Id)
            {
                nonVideoPayloads = false;
                break;
            }

            string sourcePayload = Path.Combine(work, $"source-track-{left.Id}.bin");
            string outputPayload = Path.Combine(work, $"output-track-{right.Id}.bin");
            await ExtractTrackAsync(sourceMatroska, left.Id, sourcePayload, work, cancellationToken).ConfigureAwait(false);
            await ExtractTrackAsync(outputMatroska, right.Id, outputPayload, work, cancellationToken).ConfigureAwait(false);
            scratch.Observe();
            nonVideoPayloads = await FilesEqualAsync(sourcePayload, outputPayload, cancellationToken).ConfigureAwait(false);
            DeleteFile(sourcePayload);
            DeleteFile(outputPayload);
            if (!nonVideoPayloads) break;

            string sourceTimestamps = Path.Combine(work, $"source-timestamps-{left.Id}.txt");
            string outputTimestamps = Path.Combine(work, $"output-timestamps-{right.Id}.txt");
            await ExtractTimestampsAsync(sourceMatroska, left.Id, sourceTimestamps, work, cancellationToken).ConfigureAwait(false);
            await ExtractTimestampsAsync(outputMatroska, right.Id, outputTimestamps, work, cancellationToken).ConfigureAwait(false);
            scratch.Observe();
            nonVideoPayloads = await FilesEqualAsync(sourceTimestamps, outputTimestamps, cancellationToken).ConfigureAwait(false);
            DeleteFile(sourceTimestamps);
            DeleteFile(outputTimestamps);
        }

        bool tracks = InventoriesEqual(sourceEvidence.Inventory, outputEvidence.Inventory, sourceVideoId, outputVideoId);
        bool chapters = sourceEvidence.Inventory.ChapterEntries == outputEvidence.Inventory.ChapterEntries;
        if (chapters && sourceEvidence.Inventory.ChapterEntries > 0)
        {
            string sourceChapters = Path.Combine(work, "source-chapters.xml");
            string outputChapters = Path.Combine(work, "output-chapters.xml");
            await RequiredAsync(tools.MkvExtract, [sourceMatroska, "chapters", sourceChapters], work, cancellationToken)
                .ConfigureAwait(false);
            await RequiredAsync(tools.MkvExtract, [outputMatroska, "chapters", outputChapters], work, cancellationToken)
                .ConfigureAwait(false);
            scratch.Observe();
            chapters = ChapterXmlEqual(sourceChapters, outputChapters);
            DeleteFile(sourceChapters);
            DeleteFile(outputChapters);
        }

        bool attachmentInventory = sourceEvidence.Inventory.Attachments.SequenceEqual(outputEvidence.Inventory.Attachments);
        bool attachmentPayloads = attachmentInventory;
        foreach (DvAttachmentInventory item in sourceEvidence.Inventory.Attachments)
        {
            if (!attachmentPayloads) break;
            string sourceAttachment = Path.Combine(work, $"source-attachment-{item.Id}.bin");
            string outputAttachment = Path.Combine(work, $"output-attachment-{item.Id}.bin");
            await RequiredAsync(tools.MkvExtract, [sourceMatroska, "attachments", $"{item.Id}:{sourceAttachment}"], work, cancellationToken)
                .ConfigureAwait(false);
            await RequiredAsync(tools.MkvExtract, [outputMatroska, "attachments", $"{item.Id}:{outputAttachment}"], work, cancellationToken)
                .ConfigureAwait(false);
            scratch.Observe();
            attachmentPayloads = await FilesEqualAsync(sourceAttachment, outputAttachment, cancellationToken).ConfigureAwait(false);
            DeleteFile(sourceAttachment);
            DeleteFile(outputAttachment);
        }
        bool title = sourceEvidence.Inventory.Title == outputEvidence.Inventory.Title;
        bool date = DatesEqual(sourceEvidence.Inventory.DateUtc, outputEvidence.Inventory.DateUtc);
        bool scale = sourceEvidence.Inventory.TimestampScale == outputEvidence.Inventory.TimestampScale;
        string outputTags = Path.Combine(work, "output-tags.xml");
        await ExtractTagsAsync(outputMatroska, outputTags, work, cancellationToken).ConfigureAwait(false);
        scratch.Observe();
        bool tags = XmlEqual(sourceTags, outputTags, sourceEvidence.VideoTrackUid, outputEvidence.VideoTrackUid);
        DeleteFile(sourceTags);
        DeleteFile(outputTags);
        bool metadata = title && date && scale && tags;
        string? detail = metadata ? null : $"metadata(title={title}, date={date}, timestampScale={scale}, tags={tags}; " +
            $"sourceTitle={sourceEvidence.Inventory.Title}, outputTitle={outputEvidence.Inventory.Title}; " +
            $"sourceDate={sourceEvidence.Inventory.DateUtc}, outputDate={outputEvidence.Inventory.DateUtc}; " +
            $"sourceScale={sourceEvidence.Inventory.TimestampScale}, outputScale={outputEvidence.Inventory.TimestampScale})";

        return new(profile, rpu, noEnhancement,
            baseVideo, videoTimestamps,
            nonVideoPayloads, tracks, chapters, attachmentInventory && attachmentPayloads, metadata, detail);
    }

    private async Task<string> NormalizedBaseHashAsync(string video, string name, string work,
        ScratchTracker scratch, CancellationToken cancellationToken)
    {
        string output = Path.Combine(work, name + ".hevc");
        await RequiredAsync(tools.DoviTool, ["remove", video, "-o", output], work, cancellationToken).ConfigureAwait(false);
        if (!File.Exists(output) || new FileInfo(output).Length == 0)
            throw new DvExecutionException("dovi_tool did not produce a normalized base stream for validation.");
        scratch.Observe();
        string hash = await HashFileAsync(output, cancellationToken).ConfigureAwait(false);
        DeleteFile(output);
        return hash;
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

    private static bool ChapterXmlEqual(string left, string right)
    {
        XDocument first = XDocument.Load(left);
        XDocument second = XDocument.Load(right);
        return XNode.DeepEquals(first.Root, second.Root);
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

    private static void DeleteFile(string path)
    {
        if (File.Exists(path)) File.Delete(path);
    }

    private static void RequireAllValidation(DvValidationReport validation)
    {
        if (validation.Profile81 && validation.RpuValidated && validation.EnhancementLayerAbsent &&
            validation.BaseVideoIdentical && validation.VideoTimestampsIdentical &&
            validation.NonVideoPayloadsIdentical && validation.TrackInventoryPreserved &&
            validation.ChaptersPreserved && validation.AttachmentsPreserved && validation.MetadataPreserved) return;
        throw new DvExecutionException("Independent output validation failed; the temporary file will not be promoted. " + validation);
    }

    private sealed class ScratchTracker(string transaction)
    {
        public long PeakBytes { get; private set; }

        public void Observe() => ObserveExternal(0);

        public void ObserveExternal(long externalBytes)
        {
            long total = externalBytes;
            if (Directory.Exists(transaction))
            {
                foreach (string path in Directory.EnumerateFiles(transaction, "*", SearchOption.AllDirectories))
                {
                    long length = new FileInfo(path).Length;
                    total = total > long.MaxValue - length ? long.MaxValue : total + length;
                }
            }
            PeakBytes = Math.Max(PeakBytes, total);
        }
    }
}
